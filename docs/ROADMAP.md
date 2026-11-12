# Roadmap and findings

Status as of 2026-11-12. Usage of what works today is in [README.md](../README.md).

## Done

| Step | Result |
|---|---|
| Manual run-through on the host (network, volumes, SQL + BC containers, publish via dev endpoint) | Worked, after the Rosetta fix and the partner license (see findings). |
| Script v1 (plain `docker/podman run`) | Replaced. |
| Script v2 on upstream **docker compose** (upstream's preferred method) | Done: generated `--env-file` + override layered on the upstream compose files. |
| End-to-end validation: BC 28.5 W1 + web client + license + 3 LS apps in order | Passed in 9 min on Apple Silicon / Docker Desktop. |
| Database persistence across `compose stop/start` | Verified; LS apps still installed afterwards. |

### Findings from building the environment script

1. **Rosetta crash.** The BC service tier (NST) crashes under Rosetta with `rosetta error:
   rt_tgsigqueueinfo failed in pend_signal` (exit 133), shortly after the dev endpoint comes
   up. Rosetta cannot deliver the signal .NET uses to suspend threads for GC. Fix:
   `DOTNET_INTERNAL_ThreadSuspendInjection=0` plus `DOTNET_GCHeapCount=2`. Upstream does
   not document this; worth reporting to MsDyn365Bc.On.Linux.
2. **SQL Server under emulation.** SQL Server 2022 CU18+ crashes under Rosetta, so the
   upstream macOS overlay pins CU17 (16.0.4175.1).
3. **LS Retail apps need the partner license** (`BC_LICENSE_HOST_PATH`). It is imported
   before the service tier starts.
4. **Keychain error on pull.** `docker pull` from ghcr fails on this Mac with a keychain
   credential-helper error in non-interactive sessions, even though the image is public.
   The script falls back to cached images. Pulling through the Docker engine API (unix
   socket) works if an automatic refresh is ever needed.
5. **`podman compose` lacks `--wait`.** That is why the script does its own readiness
   polling instead.
6. **Database lost on restart upstream.** Upstream keeps the database on tmpfs. The
   entrypoint reuses an existing database, so a volume makes environments survive restarts.

---

## In progress: configuration packages (optional final step)

Goal: an optional last step for the script that creates a company, then imports and applies
RapidStart configuration packages in a defined order. The test case is LS Central demo data
plus LS Central for pharmacies.

### Packages and order

Sources:
- `ls-central-280-demo-data-package/Documentation/Phase Import - To create new LS Central
  Demo Data company 28.0 .pdf` (LS Retail)
- the package contents themselves: table lists, and which keys each package defines or
  references

| # | Package file | Code | Tables / records | Notes |
|---|---|---|---|---|
| 0 | *(create a new, empty company)* | – | – | The LS doc requires a **new** company. |
| 1 | `Business Central data/NAV28.0.W1.ENU.EXTENDED.rapidstart` | `W1.ENU.EXTENDED` | 403 / 16,062 | BC base data. The doc calls it `…EVALUATION`; this release ships `EXTENDED`. Interactively it asks a few questions; the doc lists **4 known errors (item category) to ignore**. |
| 2 | *(Feature Management)* | `SalesPrices` | – | **Enable "Feature Update: New sales pricing experience"** after #1 and before the LS packs. Currently disabled (`None`), one-way, needs a data update, mandatory from BC 31. LS NO-02 loads price list headers/lines (7000/7001). |
| 3 | `PackageLSC.DEMO.PACK.NO-01` | `LSC.DEMO.PACK.NO-01` | 3 / 93 | Retail setup, distribution groups. **Must be first** of the LS packs. |
| 4 | `NO-02` | `LSC.DEMO.PACK.NO-02` | 41 / 3,427 | Filter tables (items, customers, price lists, no. series). **After NO-01, before NO-03.** |
| 5 | `NO-02A` | `LSC.DEMO.PACK.NO-02A` | 12 / 1,103 | VAT tables (not in the 2025 doc; ordered by name). |
| 6 | `NO-03` | | 13 / 2,498 | Currencies, salespeople, item variants. |
| 7 | `NO-04` | | 281 / 26,393 | "A group" tables: company info, setups, UoM, retail hierarchy… |
| 8 | `NO-05` | | 239 / 23,832 | "B group" tables, **defines the stores** (e.g. `S0015`). |
| 9 | `NO-06` | | 93 / 17,256 | Replenishment. |
| 10 | `NO-07` | | 38 / 25,953 | POS setup (menus, panels, buttons). |
| 11 | `NO-07A` | | 8 / 197 | POS profiles (not in the 2025 doc). |
| 12 | `NO-08` | | 20 / 4,743 | Actionable insights. |
| 13 | `NO-09` | | 67 / 1,795 | Bookings module. |
| 14 | `NO-10` | | 64 / 3,039 | Web KDS. |
| 15 | `NO-11` | | 23 / 1,129 | GS1, sourcing, wish lists (not in the 2025 doc). |
| 16 | `Pharmacies Configuration Packages/PackageLSPH_0` | `LSPH_0` | 4 / 194 | "Initial package": UoM, substance groups, inner pack types, prescription terminal. |
| 17 | `PackageLSPH_DEFAULT_DATA` | `LSPH_DEFAULT_DATA` | 28 / 14,534 | Pharmacy no. series (e.g. `PH-DISP-ORD`), ATC groups, drug forms, staff, barcode masks. References store `S0015` (from LS NO-05). |
| 18 | `PackageLSPH_DISPENSE` | `LSPH_DISPENSE` | 5 / 13 | Dispense setup. Uses no. series from DEFAULT_DATA and store `S0015`, so **after DEFAULT_DATA**. |
| 19 | `PackageLSPH_DEMO_DATA` | `LSPH_DEMO_DATA` | 10 / 2,212 | 603 pharmacy items, products, issuers, customers. Last. |
| 20 | *(Retail images)* | – | – | `Retail Images/Retail Image File-1..5.zip`, imported **after all packages** through *Retail Image List → Import from Zip*, then *Update Image Links*. UI action only; no API found yet. |

**Ordering rules:** BC base → SalesPrices feature → LS NO-01 → NO-02 → rest of the LS packs →
pharmacy packages (these depend on LS stores and no. series) → retail images.

Other observations:
- **Packages with and without data.** The LS demo package ships both
  `Config Packages with data/` and `Config Packages without data/`. Use **with data**;
  the other set is for building your own packages.
- **`LSPH_0` will log errors.** Its prescription terminal row references store `PH001` and
  prescription profiles `STANDARD`/`RX`/`CREDIT`, which no package creates. Expect field
  errors there.
- **Alternative to the pharmacy packages.** The pharmacy release also ships `LS
  Retail_Demo Data for LS Central for pharmacies_28.1.0.1199.app`. It generates the same
  kind of data in code via its *Pharmacy Demo Tool* page, and its terminal uses store
  `S0015`. It is not part of the package flow; consider it later, and don't run both.
- **Other files in the pharmacy release.** It also contains *Internal prescription gateway
  add-on* (app), web templates, translations and patch files. These are not needed for the
  demo data.

### Mechanism: automation API v2.0

Everything is exposed under `http://localhost:7052/BC/api/microsoft/automation/v2.0/companies({id})/…`:

| Need | API | Status |
|---|---|---|
| Create company | `POST automationCompanies {"name","displayName"}` (`evaluationCompany` is read-only) | **Works**, about 33 s. Company `LS Central Demo` now exists in `bc285`. |
| Enable SalesPrices | `features('SalesPrices')/Microsoft.NAV.activate` | Not tried yet; the data-update behaviour needs checking. |
| Create package record | `POST configurationPackages {"code","packageName"}`, code read from the file header | Works. |
| Upload file | `PATCH configurationPackages({id})/file('{code}')/content` (octet-stream, `If-Match: *`) | Works. |
| Import | `POST configurationPackages({id})/Microsoft.NAV.import`, then poll `importStatus` | **Blocked** (see blocker 2). |
| Apply | `POST …/Microsoft.NAV.apply`, then poll `applyStatus` / `numberOfErrors` | Not reached. |

Prototype (local only, `experiments/` is git-ignored): [`experiments/Import-ConfigPackages.prototype.ps1`](../experiments/Import-ConfigPackages.prototype.ps1)
(`-CompanyName`, `-Packages <ordered paths>`). It reads the package code from the gzip /
UTF-16 XML header, replaces any existing package with the same code, uploads, imports,
applies and polls.

### Blocker 1: SQL Full-Text Search (resolved, not yet in the script)

Creating a company failed with *"Text optimized index cannot be created/queried because the
SQL Server Full-Text Search component is not installed"*. Upstream's FTS image
(`mssql:2022-fts`) is built on `2022-latest`, which crashes under Rosetta.

Fix: build an FTS variant of **CU17** locally, with the FTS package pinned to the engine
build. The recipe (local only, git-ignored) is [`experiments/mssql-fts/Dockerfile`](../experiments/mssql-fts/Dockerfile):

```bash
docker build --platform linux/amd64 --build-arg ENGINE=16.0.4175.1 \
  -t bcvm/mssql:2022-CU17-fts experiments/mssql-fts
```

- The engine version comes from the base image label `com.microsoft.version`. The matching
  package is `mssql-server-fts 16.0.4175.1-3`; `sqlservr --version` does not work at build
  time.
- Verified: `SERVERPROPERTY('IsFullTextInstalled') = 1`, and company creation then works.
- `bc285` was switched to this image by **hand-editing** `~/.bcvm/bc285/compose.override.yml`
  (`image: "bcvm/mssql:2022-CU17-fts"`). The database volume was kept. The script does not
  know about this yet.

### Blocker 2: package import never runs (open)

`Microsoft.NAV.import` queues a background task, and `importStatus` stays at `Scheduled`
indefinitely (20+ min, no SQL activity, BC CPU around 10–15%).

- `[$ndo$taskscheduling]` shows the task claimed by the live server instance (state 3,
  instance 6) but never executing.
- An older CRONUS task from the first boot (07:43) never ran either. So the task scheduler
  may not execute background tasks at all on this Linux/emulated service tier.
- `EnableTaskScheduler=true` and `TaskSchedulerMaximumConcurrentRunningTasks=5` in
  `/bc/service/CustomSettings.config`. Upstream documents nothing about background tasks or
  the job queue.
- **Possibly confounded:** the SQL container was swapped under the running tier at 08:12,
  causing connection-lost errors in `NavTaskScheduler.RefreshTaskScheduleListAsync`. A clean
  BC restart to rule this out was **started but not finished** when work stopped.

Next steps, in order:
1. Finish the clean-restart test, or recreate the environment with the FTS image from the
   start. Then check whether a queued import runs.
2. If tasks still never run, test the task scheduler in isolation (any `TaskScheduler.CreateTask`
   scenario, e.g. a job queue entry). Read the NST log for the session start of the task.
   Check whether upstream has an issue for it, and report one if not.
3. If background tasks can't be made to work, ways to import/apply synchronously:
   - drive the *Configuration Packages* page through the client-services WebSocket
     (upstream already has a TestPage-capable runner in the image)
   - a small helper extension exposing an unbound API action that runs
     `Config. Package - Import`/`Config. Package Management` synchronously

   The extension needs the AL compiler (upstream documents the Linux AL tool).
4. Then: apply EXTENDED (expect 4 item-category errors), enable SalesPrices, and run the LS
   and pharmacy packages. Record per-package timings and error counts.

### Planned script design (once the blockers are solved)

The optional final step, run after the extensions:

- `-CompanyName 'LS Central Demo'`: create the company if it doesn't exist.
- `-ConfigPackages <ordered list>`: files and/or folders. Folders are sorted naturally, so
  `NO-02` < `NO-02A` < `NO-03`. Env file key `CONFIG_PACKAGES` (`;`-separated).
- `-EnableFeatures SalesPrices`, applied at a defined point. An inline step token in the
  list, e.g. `feature:SalesPrices`, would keep the order explicit in one place.
- `-MaxPackageErrors` / `-AllowedPackageErrors`: per-package tolerance (EXTENDED has 4
  known errors). Report `numberOfErrors` per package, and stop or continue as configured.
- **SQL Full-Text Search:**
  - x86 hosts: upstream `mssql:2022-fts` via `-SqlImage`.
  - ARM hosts: build `bcvm/mssql:2022-CU17-fts` from the bundled Dockerfile on first use
    (engine version from the image label).

  Turn it on automatically when a company will be created, or with an explicit
  `-FullTextSearch` switch.
- Retail images: separate, later step (needs a non-UI path).

Example env file additions:

```ini
FULL_TEXT_SEARCH=1
COMPANY_NAME=LS Central Demo
CONFIG_PACKAGES=ls-central-280-demo-data-package/Business Central data/NAV28.0.W1.ENU.EXTENDED.rapidstart;feature:SalesPrices;ls-central-280-demo-data-package/Config Packages with data;LS Central for pharmacies 28.1.0/Pharmacies Configuration Packages/PackageLSPH_0.rapidstart;…/PackageLSPH_DEFAULT_DATA.rapidstart;…/PackageLSPH_DISPENSE.rapidstart;…/PackageLSPH_DEMO_DATA.rapidstart
```

The pharmacy packages must be listed one by one, because their names don't sort into the
needed order.

---

## Backlog / open items

- **Untested platforms:** Windows (Docker Desktop), Linux (native docker), Podman (macOS
  rootful + Rosetta, Linux). The script has code paths for all of them, but only macOS +
  Docker Desktop has run.
- **`-Remove` end to end:** not run against a real environment yet (it would have deleted
  the test bench).
- **Upstream test toolkit:** the entrypoint always installs the Microsoft test toolkit and
  its Test Runner Extension. Consider exposing a "no test toolkit" option if upstream
  supports it (e.g. `BC_SKIP_APP_PUBLISH` skips all boot-time publishing).
- **Stale `/tmp/bc-ready`:** after `compose restart` the marker is stale until the
  entrypoint clears it. The script's wait also requires OData, so it's not affected, but
  ad-hoc checks are.
- **Wrong `-BcImage` builds from source:** upstream's compose has a `build:` section with
  `pull_policy: missing`, so an image name that can't be pulled is silently built from upstream
  `src/Dockerfile` (about 2 min) instead of failing. Consider checking that the image exists or
  pulls before `compose up`.
- **Image refresh:** consider pulling through the engine API when the CLI pull fails on a
  credential helper.
- **Report upstream:** the Rosetta .NET crash and its fix; CU17-based FTS for Apple Silicon.

## Current state of the test bench (`bc285`)

- Running: BC 28.5 W1, web client on :8080, LS Central System App / LS Central / LS
  Central for pharmacies installed.
- SQL image switched by hand to `bcvm/mssql:2022-CU17-fts` (see blocker 1).
- Company **`LS Central Demo`** was created through the API. It still holds a configuration
  package record `W1.ENU.EXTENDED` with `importStatus = Scheduled`, which never ran.
  Delete it (or the whole company) before the next attempt.
