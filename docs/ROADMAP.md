# Roadmap and findings

Status as of 2026-11-14. Usage of what works today is in [README.md](../README.md).

## Done

| Step | Result |
|---|---|
| Manual run-through on the host (network, volumes, SQL + BC containers, publish via dev endpoint) | Worked, after the Rosetta fix and a partner license (see findings). |
| Script v1 (plain `docker/podman run`) | Replaced. |
| Script v2 on upstream **docker compose** (upstream's preferred method) | Done: generated `--env-file` + override layered on the upstream compose files. |
| End-to-end validation: BC 28.5 W1 + web client + partner license + 3 ISV apps in dependency order | Passed in 9 min on Apple Silicon / Docker Desktop. |
| Database persistence across `compose stop/start` | Verified; apps still installed afterwards. |

### Findings from building the environment script

1. **Rosetta crash.** The BC service tier (NST) crashes under Rosetta with `rosetta error:
   rt_tgsigqueueinfo failed in pend_signal` (exit 133), shortly after the dev endpoint comes
   up. Rosetta cannot deliver the signal .NET uses to suspend threads for GC. Fix:
   `DOTNET_INTERNAL_ThreadSuspendInjection=0` plus `DOTNET_GCHeapCount=2`. Upstream does
   not document this; worth reporting to MsDyn365Bc.On.Linux.
2. **SQL Server under emulation.** SQL Server 2022 CU18+ crashes under Rosetta, so the
   upstream macOS overlay pins CU17 (16.0.4175.1).
3. **ISV apps need a partner license** (`BC_LICENSE_HOST_PATH`). It is imported before the
   service tier starts.
4. **Credential helper breaks pulls.** A `credsStore` helper that is missing (`desktop` left
   behind after switching to Kiri) or can't reach the keychain fails every pull, even of public
   images. Upstream's `bc` service then falls back to its `build:` section and builds the runner
   from source, and that local image shadows the published one afterwards (`pull_policy:
   missing`). The script now runs `compose up --no-build` and names the credential problem.
7. **Kiri works as the engine.** Docker-compatible, Rosetta for amd64. Leftovers of an
   uninstalled Docker Desktop (dangling `/usr/local/bin/docker`, stale `desktop-linux`
   context) made the script pick a dead CLI/engine; detection now skips dangling links and
   reports the context.
5. **`podman compose` lacks `--wait`.** That is why the script does its own readiness
   polling instead.
6. **Database lost on restart upstream.** Upstream keeps the database on tmpfs. The
   entrypoint reuses an existing database, so a volume makes environments survive restarts.

---

## In progress: configuration packages (optional final step)

Goal: an optional last step for the script that creates a company, then imports and applies
RapidStart configuration packages in a defined order (for example BC base data, then the
demo data packages of an ISV solution).

### Mechanism: automation API v2.0

Everything is exposed under `http://localhost:7052/BC/api/microsoft/automation/v2.0/companies({id})/…`:

| Need | API | Status |
|---|---|---|
| Create company | `POST automationCompanies {"name","displayName"}` (`evaluationCompany` is read-only) | **Works** (about 33 s), once SQL Full-Text Search is available. |
| Enable a feature (e.g. `SalesPrices`) | `features('SalesPrices')/Microsoft.NAV.activate` | Not tried yet; the data-update behaviour needs checking. |
| Create package record | `POST configurationPackages {"code","packageName"}`, code read from the file header | Works. |
| Upload file | `PATCH configurationPackages({id})/file('{code}')/content` (octet-stream, `If-Match: *`) | Works. |
| Import | `POST configurationPackages({id})/Microsoft.NAV.import`, then poll `importStatus` | **Blocked** (see blocker 2). |
| Apply | `POST …/Microsoft.NAV.apply`, then poll `applyStatus` / `numberOfErrors` | Not reached. |

The package code is read from the gzip / UTF-16 XML header of the `.rapidstart` file.

### Blocker 1: SQL Full-Text Search (resolved, not yet in the script)

Creating a company fails with *"Text optimized index cannot be created/queried because the
SQL Server Full-Text Search component is not installed"*. Upstream's FTS image
(`mssql:2022-fts`) is built on `2022-latest`, which crashes under Rosetta.

Fix: build an FTS variant of **CU17**, with the FTS package pinned to the engine build:

- Base image: `mcr.microsoft.com/mssql/server:2022-CU17-ubuntu-22.04`, platform
  `linux/amd64`.
- The engine version comes from the base image label `com.microsoft.version`
  (`16.0.4175.1`). The matching package is `mssql-server-fts 16.0.4175.1-3`;
  `sqlservr --version` does not work at build time.
- Verified: `SERVERPROPERTY('IsFullTextInstalled') = 1`, and company creation then works.
- Use it with `-SqlImage`. The script does not build it yet (see planned design).

### Blocker 2: package import never runs (open)

`Microsoft.NAV.import` queues a background task, and `importStatus` stays at `Scheduled`
indefinitely (20+ min, no SQL activity, BC CPU around 10–15%).

- `[$ndo$taskscheduling]` shows the task claimed by the live server instance but never
  executing. A task queued on first boot never ran either, so the task scheduler may not
  execute background tasks at all on this Linux/emulated service tier.
- `EnableTaskScheduler=true` and `TaskSchedulerMaximumConcurrentRunningTasks=5` in
  `/bc/service/CustomSettings.config`. Upstream documents nothing about background tasks or
  the job queue.
- **Possibly confounded:** the SQL container was swapped under the running tier during the
  test, causing connection-lost errors in `NavTaskScheduler.RefreshTaskScheduleListAsync`.
  A clean restart to rule this out was not finished.

Next steps, in order:
1. Recreate an environment with the FTS image from the start, then check whether a queued
   import runs.
2. If tasks still never run, test the task scheduler in isolation (any `TaskScheduler.CreateTask`
   scenario, e.g. a job queue entry). Read the NST log for the session start of the task.
   Check whether upstream has an issue for it, and report one if not.
3. If background tasks can't be made to work, ways to import/apply synchronously:
   - drive the *Configuration Packages* page through the client-services WebSocket
     (upstream already has a TestPage-capable runner in the image)
   - a small helper extension exposing an unbound API action that runs
     `Config. Package - Import`/`Config. Package Management` synchronously

   The extension needs the AL compiler (upstream documents the Linux AL tool).

### Planned script design (once the blockers are solved)

The optional final step, run after the extensions:

- `-CompanyName 'My Demo'`: create the company if it doesn't exist.
- `-ConfigPackages <ordered list>`: files and/or folders. Folders are sorted naturally, so
  `NO-02` < `NO-02A` < `NO-03`. Env file key `CONFIG_PACKAGES` (`;`-separated).
- `-EnableFeatures SalesPrices`, applied at a defined point. An inline step token in the
  list, e.g. `feature:SalesPrices`, would keep the order explicit in one place.
- `-MaxPackageErrors` / `-AllowedPackageErrors`: per-package tolerance (some base packages
  have known errors). Report `numberOfErrors` per package, and stop or continue as configured.
- **SQL Full-Text Search:**
  - x86 hosts: upstream `mssql:2022-fts` via `-SqlImage`.
  - ARM hosts: build a CU17 FTS image from a Dockerfile embedded in the script on first use
    (engine version from the image label).

  Turn it on automatically when a company will be created, or with an explicit
  `-FullTextSearch` switch.

Example env file additions:

```ini
FULL_TEXT_SEARCH=1
COMPANY_NAME=My Demo
CONFIG_PACKAGES=packages/NAV28.0.W1.ENU.EXTENDED.rapidstart;feature:SalesPrices;packages/demo-data
```

---

## Backlog / open items

- **Untested platforms:** Windows (Docker Desktop), Linux (native docker), Podman (macOS
  rootful + Rosetta, Linux). The script has code paths for all of them, but only macOS +
  Docker Desktop has run.
- **`-Remove` end to end:** not run against a full environment yet.
- **Upstream test toolkit:** the entrypoint always installs the Microsoft test toolkit and
  its Test Runner Extension. Consider exposing a "no test toolkit" option if upstream
  supports it (e.g. `BC_SKIP_APP_PUBLISH` skips all boot-time publishing).
- **Stale `/tmp/bc-ready`:** after `compose restart` the marker is stale until the
  entrypoint clears it. The script's wait also requires OData, so it's not affected, but
  ad-hoc checks are.
- **Image refresh:** consider pulling anonymously (engine API) when the CLI pull fails on a
  credential helper; today the script names the cause and uses cached images.
- **Podman with libkrun** (default provider on new Podman for macOS): amd64 runs under qemu-user,
  not Rosetta. Untested; SQL Server may not run under qemu.
- **Report upstream:** the Rosetta .NET crash and its fix; CU17-based FTS for Apple Silicon.
