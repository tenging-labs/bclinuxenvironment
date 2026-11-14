# Roadmap and findings

Status as of 2026-11-14 (configuration packages done). Usage of what works today is in [README.md](../README.md).

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
4. **Slow requests through the engine's proxies.** Kiri's name router cut the ~30 s company creation
   at 30 s (BC then cancels it), and Kiri's port forwarding drops connections idle for 300 s. All
   package calls therefore run inside the bc container.

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
