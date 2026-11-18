# Roadmap and findings

Status as of 2026-11-16 (configuration packages, snapshots/clones and environment administration done). Usage of what works today is in [README.md](../README.md).

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
8. **Kiri's port forwarding drops connections idle for 300 s.** Measured: a host server
   answering after 330 s works; the same through a Kiri published port fails at 301 s. A
   host-side publish POST of LS Central (> 300 s) was cut, BC logged `TaskCanceledException` and
   restored the previous extensions. Publishing now runs inside the bc container (detached
   curl to `localhost:7049`, result file polled), so no long host connection exists.
5. **`podman compose` lacks `--wait`.** That is why the script does its own readiness
   polling instead.
6. **Database lost on restart upstream.** Upstream keeps the database on tmpfs. The
   entrypoint reuses an existing database, so a volume makes environments survive restarts.

---

## Done: company and configuration packages (`-CompanyName`, `-ConfigPackages`)

Validated 2026-11-14 on Kiri / Apple Silicon, BC 28.5 W1 + LS Central: new company, BC `EXTENDED`
package (403 tables, 15,834 records: import 300 s, apply 335 s, the 4 known item-category errors),
`SalesPrices` feature, then the LS Central and pharmacy demo packages in their documented order.

**Mechanism:** automation API v2.0, called with curl inside the bc container:
`automationCompanies` (create) → per package `configurationPackages` create →
`PATCH file('{code}')/content` → `Microsoft.NAV.import` → poll `importStatus` → `Microsoft.NAV.apply`
→ poll `applyStatus`/`numberOfErrors`; `features('{id}')/Microsoft.NAV.activate`
(`updateInBackground: false` and `startDateTime` are both required).

What had to be solved on the Linux tier (upstream reports drafted, not filed yet):

1. **SQL Full-Text Search.** Creating a company fails with *"Text optimized index cannot be
   created/queried because the SQL Server Full-Text Search component is not installed"*. Upstream's
   `mssql:2022-fts` is built on `2022-latest`, which crashes under Rosetta, so ARM hosts build CU17 +
   `mssql-server-fts 16.0.4175.1-3` (engine build `16.0.4175.1`) from a Dockerfile embedded in the
   script.
2. **Background tasks never ran** (the old "stays Scheduled" blocker). Two causes:
   - `TaskRunner.InternalRunAsync` → `NavPerformanceCounterSetter.NativeMethods.QueryPerformanceCounter`
     is imported from **`Kernel32.dll`** (capital K; every other kernel32 import in `Nav.Ncl` is lower
     case). Upstream's stub library has the function, but its resolver compares names
     case-sensitively and links only `kernel32.dll` → `DllNotFoundException`; the task stays claimed
     (`[$ndo$taskscheduling].state = 3`) forever. Fix: `/bc/service/Kernel32.dll` → `libwin32_stubs.so`.
   - Upstream inserts the bootstrap user with a fixed **Windows Security ID**, so the task scheduler
     refreshes the user's Windows groups via `System.DirectoryServices` (`kernel32!CompareString`,
     not stubbed) → `EntryPointNotFoundException`, retried with back-off. Fix: clear the SID (a
     NavUserPassword user has none) and restart the tier.
3. **Parallel table import** (`Config. XML Exchange` → `Parallel Session Management` →
   `Memory Mapped File.CreateOrOpen`) fails with *"Named maps are not supported"* on .NET/Linux. Every
   table with ≥ `MinCountForAsyncImport` rows (package header attribute, default 5; the header
   overrides the package record) goes that way. Fix: upload a copy with the attribute set to
   `2147483647`, so tables import synchronously.
4. **Slow requests through the engine's proxies.** The ~30 s company creation was cut at 30 s when sent
   through `http://api.<name>.kiri.local` (BC then cancels it), and Kiri's port forwarding drops
   connections idle for 300 s. All package calls therefore run inside the bc container.
   Re-measured 2026-11-16: the Kiri **name router itself does not cut** slow responses (a test server
   answering GET/POST after 40, 70, 320 and 620 s all returned 200). So the 30 s cut came from
   somewhere else (client or the generated nginx config), still to be found; see "Environment
   administration" below.

Useful for diagnosis: `BC_DEBUG_FIRSTCHANCE=1` (upstream #44) shows exceptions BC normally redacts;
the task scheduler logs as `Category: TaskScheduling`; scheduled tasks are in `[Scheduled Task]` and
`[$ndo$taskscheduling]`.

### Order used for the LS Central demo company

BC `EXTENDED` → `feature:SalesPrices` → LS `NO-01`, `NO-02`, `NO-02A`, `NO-03` … `NO-11` (folder order
works) → pharmacy `LSPH_0`, `LSPH_DEFAULT_DATA`, `LSPH_DISPENSE`, `LSPH_DEMO_DATA` (listed one by one).
Vendor-specific notes are local only (`experiments/config-packages-notes.md`).

### Not done

- **Retail images** (`Retail Image List → Import from Zip`, `Update Image Links`): UI actions, no API.
- **Per-package error thresholds** (`-MaxPackageErrors`): apply errors are only reported.
- **Faster import**: the synchronous path imports tables one at a time; an emulation of named
  memory-mapped files in the image would allow BC's parallel import again.

---

## Done: snapshots and clones (`-Snapshot`, `-Clone`)

Implemented 2026-11-16. Usage in the README ("Snapshots and clones"). `-Snapshot` keeps the database;
`-Clone` keeps the whole environment, so a new one starts without downloading artifacts, re-patching
the tier or drifting to another BC build or runner image.

### Where an environment's state lives

| Volume (compose project `<Name>`) | Content | Size, BC 28.5 + LS Central |
|---|---|---|
| `sql-data` → `/var/opt/mssql` | SQL Server: `CRONUS` database (data, apps, companies, license, users) + system DBs | 1.9 GB |
| `bc-artifacts` → `/bc/artifacts` | Downloaded app + platform artifacts, stamped `.bc-artifact-cache` | 3.2 GB |
| `bc-service` → `/bc/service` | Patched service tier, stamped (`SERVICE_STAMP`: platform, image `StartupHook.dll`, patcher, SQL config) | 0.7 GB |
| `bc-assembly-cache` → `/bc/assembly-cache` | Compiled (R2R) assemblies, stamped with platform + image | 0.9 GB |

The bc container's writable layer holds only what the entrypoint recreates every boot (runtime DLL
patches, `/tmp/bc-ready`), so `docker commit` isn't needed (and would miss the volumes). The upstream
entrypoint skips work on warm volumes: artifacts whose stamp matches are not downloaded, a matching
service stamp skips patching, and an existing `CRONUS` database is reused.

### How it works

- **`-Snapshot`:** `BACKUP … COPY_ONLY, COMPRESSION, CHECKSUM` in the running sql container, copied to
  `~/.bcvm/snapshots/<snap>/database.bak`; `snapshot.json` records the exact build (from the `key=`
  line of `/bc/artifacts/.bc-artifact-cache`), country, type, license path, user, database name, FTS,
  companies and non-global apps.
- **`-FromSnapshot`:** settings pinned from `snapshot.json` (an explicit different version, country,
  type or artifact URL is refused). `compose up sql`, wait, `RESTORE … WITH REPLACE, MOVE …`, clear the
  user's Windows Security ID, then `compose up`. The entrypoint downloads the exact build and reuses the
  database.
- **`-RestoreSnapshot`:** same build only; stop `bc`, restore, start `bc`, wait.
- **`-Clone`:** volumes found through the containers' mounts (the label lookup missed a volume created
  outside compose); `compose stop`, copy each into `bcvm-clone-<clone>-<volume>` (`run --rm … cp -a`
  with the runner image), `compose start`, wait. `clone.json` keeps the source's settings verbatim (the
  artifact stamp compares the request string, `args|sandbox|28.5|w1`: rewriting `28.5` to the full
  build would re-download), the runner image by RepoDigest, the SQL image and the `sa` password (it
  lives in the copied `master`).
- **`-FromClone`:** creates `<Name>_<volume>` with compose labels as copies of the clone's volumes, pins
  the image, then the normal `compose up`.
- **Why a database moves between environments:** every environment uses the same fixed public
  encryption key (inserted by the entrypoint), the license is re-imported from the mount at every boot
  (the target's license wins; the snapshot's is the default), and the Windows Security ID fix is stored
  in the database. The `Kernel32.dll` link is re-applied after readiness (it lives in `bc-service`).

### Measured (2026-11-16, Kiri on Apple Silicon, BC 28.5 W1 + LS Central, pharmacy, System App)

| Operation | Time | Notes |
|---|---|---|
| `-Snapshot` | 5 s | 749 MB file; BC keeps running |
| `-Clone` | 145 s | volume copy 18 s (6.6 GB); the rest is the source's stop and warm restart |
| `-FromClone` | 3.5 min to ready | copies 7 s; "Artifacts already cached — skipping download", "CRONUS already exists"; all apps installed; web client redirects to the new name |
| `-FromSnapshot` | ~6 min | restore 15 s, then download (46 s) + cold boot like a new environment (this run took 27 min because of the memory problem below) |
| `-RestoreSnapshot` | 228 s | restore seconds, the rest is the tier's warm boot |
| Fresh environment, same build | ~6 min | for comparison (42 s download) |

What remains in a clone start is the tier's boot and upstream's test-toolkit publishing at every start.

**Memory limit found while testing:** with three BC environments running on Kiri (VM ceiling 20 GB),
a fourth booting environment's SQL Server failed with error 701 ("insufficient system memory"), BC
stopped during boot and the container restarted in a loop. Containers used ~10 GB, but the VM had
15 MB available: the rest was not processes or page cache, most likely held by Kiri's balloon. After
removing one environment, 3.5 GB came back. Plan for about 3.5–4 GB per environment.

### Open

- **Data encryption keys:** with `EnableEncryption`, the key file sits in the bc container, not in the
  database. Not checked whether it is in `bc-service` (a clone would keep it) or lost.
- **Moving clones between machines:** engine volumes are not portable; an `-ExportClone`/`-ImportClone`
  to a `tar` (~7 GB) would be needed.
- A shared artifact cache across environments (upstream's `BC_ARTIFACTS_DIR`) would also remove most
  of the download cost for new environments of the same build.

---

## Done: environment administration (apps and configuration packages)

Implemented 2026-11-16. Usage in the README ("Administering a running environment").

- **Script:** `-ListApps` (`-AsJson`), `-UninstallApp`/`-UnpublishApp`/`-InstallApp` (by name, app id
  or package id; `-DeleteData`), and `-Update` to publish `-Apps` and import `-CompanyName`/
  `-ConfigPackages` into a running environment with the same in-container calls as at creation. Modes
  on existing environments read the environment's settings from its `compose.env`/override.
- **Router (`-PortlessRouter`):** `<Name>.kiri.local` forwards `/BC/api/`, `/BC/dev/` and `/BC/ODataV4/`
  to BC with the environment's login added. `-Update` rewrites the page and router config of older
  environments and reloads nginx.
- **Sharing (`kiri share <Name>-router-1`):** Kiri Cloud sends `Host: localhost:<port>` with the public
  name in `X-Forwarded-Host` and `X-Forwarded-Proto: https` (verified 2026-11-18), so a share used to hit
  the router's `default_server` 404. The default server is now a public gateway without credentials:
  by share-name prefix (`dev-/odata-/api-/client-/bc-<Name>`) or by path (`/BC/ODataV4/`, `/BC/api/`,
  `/BC/dev/`, else the web client). For the web client it passes the public name as `Host`, rewrites
  an `https://<public>` Origin to `http://` and turns `http://` redirects into `https://` (no bc
  recreate, unlike upstream's `BC_WEBCLIENT_TRUST_FORWARDED_HEADERS`). Verified with curl: redirect,
  sign-in, OData/API with auth, name routing, status page not exposed. Browser session (WebSocket
  `/csh`) not yet confirmed.
- **Status page:** Extensions card (install, uninstall, unpublish, publish `.app` files) and
  Configuration packages card (company picker, create company, import and apply `.rapidstart` files,
  apply/delete existing packages). The `MinCountForAsyncImport` rewrite runs in the browser
  (`DecompressionStream`/`CompressionStream`, UTF-16 kept); tested in Node against the script's output
  (identical except the attribute).

### Findings

- The automation API v2.0 has every action needed: `extensions` → `Microsoft.NAV.install`, `uninstall`,
  `uninstallAndDeleteExtensionData`, `unpublish` (key `packageId`); `extensionUpload` +
  `Microsoft.NAV.upload` (asynchronous, tenant scope; not used). Listing extensions takes ~1 s.
- Install/uninstall of LS Central for pharmacies: 4–7 s, synchronous (HTTP 204), through the script and
  through the router.
- Install/uninstall/unpublish of LS Central for pharmacies: 6–8 s each; a publish of it through the
  router (`/BC/dev/apps`): 88 s, HTTP 200. Company creation through the router: 66–110 s, HTTP 201.
  Package NO-01 over HTTP (create, upload, import, apply): import 3 tables / 93 records, 0 errors.
- **Kiri's 30 s cut, explained (2026-11-16).** Kiri's name router closes a request after exactly 30 s
  without a response **when the backend keeps reading from the connection** meanwhile. nginx does
  (it watches the client for an early close), as does a plain socket server polling `recv`; Python's
  `http.server` and a server that just sleeps don't, which is why the earlier 620 s test passed. Not
  related to compose, keep-alive, multiple names on the label or emulation (each tested). nginx then
  logged 499 and aborted the upstream request, and BC cancelled the operation (the company never
  appeared). **Fix:** `proxy_ignore_client_abort on;` in the router: nginx stops reading from the
  client while it waits, and Kiri no longer cuts (company creation 66 s and 79 s, publish 88 s, all
  answered). This also covers AL publishes from VS Code through `dev.<Name>.kiri.local`. The page
  additionally falls back to waiting for the outcome if a connection is dropped. Worth reporting to
  Kiri (draft in `experiments/upstream-issues.md`, local).
- Containers have: bc: `curl`, `python3`, `perl`, `gzip`, .NET 8/10 runtimes, no `pwsh`; sql:
  `python3`, `sqlcmd`; router (nginx:alpine): busybox, `nc`, `curl`.

### Open

- Agents using the raw HTTP API must rewrite `MinCountForAsyncImport` themselves (documented). A small
  job runner (e.g. the bc container's `python3`) could hide that, at the cost of a second language.
- Snapshots, clones and restores are script-only (nginx cannot run them).
- Features (`feature:<Id>` steps) are script-only on the page.

---

## Backlog / open items

- **Untested platforms:** Windows (Docker Desktop), Linux (native docker), Podman (macOS
  rootful + Rosetta, Linux). The script has code paths for all of them, but only macOS +
  Docker Desktop has run.
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
