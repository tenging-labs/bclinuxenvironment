# bclinuxenvironment: Business Central environments in Docker or Podman

`Invoke-BcLinuxEnvironment.ps1` creates a Microsoft Dynamics 365 Business Central environment in a
local container engine. It then installs your extensions (`.app` files) in the order you
give them. One PowerShell script works the same way on Windows, Linux and macOS.

It is built on [MsDyn365Bc.On.Linux](https://github.com/aldevtools/MsDyn365Bc.On.Linux),
which runs the unmodified BC service tier on Linux. The script uses that project's
supported workflow (`docker compose up`) and adds what the upstream workflow leaves to you:

- uses your docker CLI and its current context (Docker Desktop, Kiri, OrbStack, Docker Engine, …) or Podman
- handles emulation on ARM machines
- supports a partner license
- keeps the database across restarts
- publishes extensions in order and verifies they are installed
- creates and removes environments by name

Work in progress (configuration packages and other open items) is tracked in
[docs/ROADMAP.md](docs/ROADMAP.md).

---

## Quick start

No parameters are needed. This starts the **latest public BC release** as a W1 sandbox, with the
web client, in an environment named `bc`:

```powershell
./Invoke-BcLinuxEnvironment.ps1
```

Or straight from GitHub, without cloning (PowerShell 7; other shells in
[Run without cloning](#run-without-cloning)):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1)))
```

More options:

```powershell
# Settings from an env file
./Invoke-BcLinuxEnvironment.ps1 -EnvFile ./example.env

# With a partner license and your apps (one string, ';'-separated, installed in that order)
./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -BcVersion 28.5 -Country w1 `
    -LicenseFile ./dev.bclicense `
    -Apps './apps/Dependency.app;./apps/MyApp.app'

# Remove an environment again (containers, network, volumes, state); the default one is 'bc'
./Invoke-BcLinuxEnvironment.ps1 -Name bc -Remove
```

When the script finishes, it prints the endpoints:

| What          | Default URL / value                       |
|---------------|-------------------------------------------|
| Web client    | http://localhost:8080/ (on by default; off with `-WebClient:$false`) |
| Dev endpoint  | http://localhost:7049/BC/dev (publish apps, download symbols) |
| OData v4      | http://localhost:7048/BC/ODataV4          |
| API v2.0      | http://localhost:7052/BC/api/v2.0         |
| Management    | http://localhost:7045/BC/Management       |
| Client services (WebSocket) | ws://localhost:7085/BC      |
| SQL Server    | `localhost,11433`, user `sa`              |
| BC login      | `BCRUNNER` / `Admin123!` (NavUserPassword, SUPER) |

---

## Run without cloning

The script is a single self-contained file (it fetches the upstream compose files itself), so
it can run straight from GitHub. No account or token is needed. You only need **PowerShell 7**
(`pwsh`) installed; it runs the script whichever shell you start from.

The script URL is:

```text
https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1
```

Paths you pass (license, apps, `-EnvFile`) are local files and resolve against your **current
directory**. The parameters are the same as for `./Invoke-BcLinuxEnvironment.ps1`; see
[Settings](#settings).

> **App lists:** pass `-Apps` as **one quoted string, separated by `;`**, e.g.
> `-Apps 'a.app;b.app;c.app'`. That form works the same in every shell and matches `APPS=` in env
> files. In PowerShell a normal array (`-Apps 'a.app','b.app'`) also works. A folder
> (`-Apps ./apps`) installs every `.app` in it, sorted by name.

### PowerShell 7 (Windows, macOS, Linux)

Everything after the closing `)))` is the normal parameter list:

```powershell
# Latest public BC release, W1 sandbox, web client (environment 'bc')
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1)))

# BC 28.5 W1 + partner license + your apps, installed in this order
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1))) -Name bc285 -BcVersion 28.5 -Country w1 `
    -LicenseFile ./dev.bclicense `
    -Apps './apps/Dependency.app;./apps/MyApp.app'

# A specific BC version next to it (every port +100: web 8180, dev 7149, OData 7148, SQL 11533, ...)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1))) -Name bc290 -BcVersion 29.0 -PortOffset 100

# Everything from an env file, on a third set of ports (+200)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1))) -EnvFile ./my.local.env -PortOffset 200

# All apps from a folder, German localization, no web client
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1))) -Name bc285de -BcVersion 28.5 -Country de -Apps ./apps -LicenseFile ./dev.bclicense -WebClient:$false

# Throw-away environment: in-memory database, replaces an existing one of the same name
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1))) -Name scratch -PersistDatabase:$false -Recreate

# Remove an environment (containers, volumes, ~/.bcvm/<Name>)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1))) -Name bc290 -Remove
```

**As a command for the session.** Load the script once per session, or put the first line in
your `$PROFILE`. Then `Invoke-BcLinuxEnvironment` works like the script, with tab completion:

```powershell
Set-Item function:global:Invoke-BcLinuxEnvironment ([scriptblock]::Create((irm https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1)))

Invoke-BcLinuxEnvironment -Name bc290 -BcVersion 29.0 -PortOffset 100
Invoke-BcLinuxEnvironment -Name bc290 -Remove
```

Don't wrap the script as `function x { & $sb @args }`: forwarding through `@args` breaks switches
written as `-Switch:$false`. Defining the function with the script as its body, as above, binds
every parameter natively.

### zsh / bash (macOS, Linux, WSL)

Download to a temp file and run it with `pwsh -File`. As a one-liner (latest public release,
W1 sandbox; append parameters as needed):

```bash
curl -fsSL https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1 -o "${TMPDIR:-/tmp}/Invoke-BcLinuxEnvironment.ps1" && pwsh -NoProfile -File "${TMPDIR:-/tmp}/Invoke-BcLinuxEnvironment.ps1"
```

For regular use, add a function to `~/.zshrc` or `~/.bashrc`. It fetches the latest script on
every call:

```bash
bclinux() {
  local f="${TMPDIR:-/tmp}/Invoke-BcLinuxEnvironment.ps1"
  curl -fsSL https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1 -o "$f" \
    && pwsh -NoProfile -File "$f" "$@"
}
```

```bash
bclinux                       # latest public release, W1 sandbox, web client

bclinux -Name bc285 -BcVersion 28.5 -Country w1 \
  -LicenseFile ./dev.bclicense \
  -Apps './apps/Dependency.app;./apps/MyApp.app'

bclinux -Name bc290 -BcVersion 29.0 -PortOffset 100
bclinux -EnvFile ./my.local.env -PortOffset 200
bclinux -Name bc285de -BcVersion 28.5 -Country de -Apps ./apps -WebClient:false
bclinux -Name bc290 -Remove
```

Quoting in zsh/bash:

- Line continuation is `\` (PowerShell uses a backtick).
- Turn a switch off with **`-WebClient:false`** (no `$`); `pwsh -File` accepts it in every shell.
  (Inside PowerShell itself it is `-WebClient:$false`; `:false` is an error there.)
  Unquoted `-WebClient:$false` loses its value (the shell expands `$false` to nothing), and the script
  stops with a message saying so. Put single quotes around anything with spaces.
- `;` must be inside the quotes; unquoted it ends the shell command.

### fish

```fish
function bclinux
    set -l f /tmp/Invoke-BcLinuxEnvironment.ps1
    curl -fsSL https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1 -o $f
    and pwsh -NoProfile -File $f $argv
end
```

Usage and quoting are the same as for bash. Not tested yet.

### Windows Command Prompt (cmd.exe)

`curl.exe` ships with Windows 10 and later:

```bat
curl -fsSL https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/main/Invoke-BcLinuxEnvironment.ps1 -o "%TEMP%\Invoke-BcLinuxEnvironment.ps1" && pwsh -NoProfile -File "%TEMP%\Invoke-BcLinuxEnvironment.ps1"
```

Use double quotes for values with spaces (`-Apps "a.app;b.app"`). Turn switches off with
`-WebClient:false`. Line continuation is `^`. Not tested yet.

### Windows PowerShell 5.1

The script needs PowerShell 7. Type `pwsh` to start a PowerShell 7 session, then use the
[PowerShell 7](#powershell-7-windows-macos-linux) examples.

### Pin a version

`main` always gives the latest script. For reproducible runs, replace `main` in the URL with a
tag or commit:

```text
https://raw.githubusercontent.com/tenging-labs/bclinuxenvironment/v1.0.0/Invoke-BcLinuxEnvironment.ps1
```

GitHub caches raw files for a few minutes, so a push to `main` can take up to about 5 minutes
to show up at the URL.

---

## Requirements

| Requirement | Notes |
|---|---|
| PowerShell 7.2+ (`pwsh`) | Windows PowerShell 5.1 is not supported (the script uses `Invoke-WebRequest -Form`). |
| A Docker-compatible engine **or** Podman, running | `docker` is used with its **current context**: Docker Desktop, [Kiri](https://runkiri.com/), OrbStack, Colima, Docker Engine, … Podman is used when no `docker` CLI exists, or with `-Engine podman`. |
| Compose v2 | `docker compose` (bundled with Docker Desktop and Kiri), or `podman compose` with `docker-compose` as its provider. |
| `git` (optional) | Fetches the upstream repo. Without git, the script downloads a zip from GitHub instead. |
| Memory | About 6 GB free for the containers (SQL 3 GB + BC 2–3 GB). On Docker Desktop / Kiri / podman machine, give the VM 12–16 GB. |
| Disk | About 5 GB per environment (artifacts, service tier, database), plus about 2 GB of images. |

### Apple Silicon / ARM hosts

The BC runner image is `linux/amd64` only, so on ARM it runs under emulation. The script
detects this and applies the needed fixes automatically (see
[What the script does](#what-the-script-does)).

- **Docker Desktop:** enable *Use Rosetta for x86_64/amd64 emulation* in Settings → General.
- **Kiri:** uses Rosetta automatically; install it once with `softwareupdate --install-rosetta`.
- **Podman:** the machine must be **rootful** and created with Rosetta enabled. See
  upstream [MacOS.md](https://github.com/aldevtools/MsDyn365Bc.On.Linux/blob/master/MacOS.md).
  The script warns if the podman machine is rootless.

---

## Configuration

Every setting can come from four places. Later ones win:

1. built-in defaults
2. an env file passed with `-EnvFile` (`KEY=VALUE` lines, `#` comments)
3. `BCVM_<KEY>` environment variables (e.g. `BCVM_BC_VERSION=28.4`)
4. script parameters

Relative paths in an env file (apps, license) are resolved against the env file's folder.

### Settings

| Parameter | Env file key | Default | Description |
|---|---|---|---|
| `-Name` | `NAME` | `bc` | Environment name = compose project name. Lowercase letters, digits, `_`, `-`. Containers are `<Name>-bc-1` and `<Name>-sql-1`. |
| `-BcVersion` | `BC_VERSION` | `latest` | `latest`: the newest public release for `-BcType`/`-Country`, read from Microsoft's artifact index when the environment is created (insider builds are never picked). Short (`28.5`): the newest build of that version. Or a full build number. The resolved build is stored, so stop/start keeps it. |
| `-Country` | `BC_COUNTRY` | `w1` | Localization (`w1`, `us`, `de`, `dk`, `is`, …). |
| `-BcType` | `BC_TYPE` | `sandbox` | `sandbox` or `onprem` artifacts. |
| `-ArtifactUrl` | `BC_ARTIFACT_URL` | – | Explicit artifact URL; overrides version/country/type. |
| `-Username` | `BC_SERVER_USERNAME` | `BCRUNNER` | BC login created with SUPER. |
| `-Password` | `BC_SERVER_PASSWORD` | `Admin123!` | Its password. |
| `-SaPassword` | `SA_PASSWORD` | `Passw0rd123!` | SQL Server `sa` password. |
| `-WebClient` | `BC_WEBCLIENT` (`1`/`0`) | **on** | Self-host the BC web client. Turn it off with `-WebClient:$false` or `BC_WEBCLIENT=0`. |
| `-LicenseFile` (alias `-BcLicenseHostPath`) | `BC_LICENSE_HOST_PATH` or `LICENSE_FILE` | – | `.bclicense` imported **before** the service tier starts, instead of the CRONUS demo license. Required for ISV apps such as LS Central. |
| `-Apps` | `APPS` | – | `.app` files and/or folders, published in the given order: one string separated by `;` (`'a.app;b.app'`), or a PowerShell array. See below. |
| `-ContainerEnv` | any other key | – | Extra environment variables for the BC container (hashtable). In an env file, every unknown key is passed through, e.g. `BC_SERVER_SETTINGS=…`. |
| `-PortlessRouter` | `PORTLESS_ROUTER` (`1`/`0`) | off | **Kiri only.** Publish no host ports and add a small nginx `router` container, so every BC endpoint gets a name (`bc.`, `dev.`, `odata.`, `api.`, `client.<Name>.kiri.local`). Environments never collide on ports. A port given explicitly (e.g. `-SqlPort 11433`) is still published. See [Container names (Kiri)](#container-names-kiri). |
| `-PortOffset` | `PORT_OFFSET` | `0` | Added to every default port, so several environments can run side by side. |
| `-DevPort` `-ODataPort` `-ApiPort` `-MgmtPort` `-ClientPort` `-WebClientPort` `-SqlPort` | `BC_DEV_PORT` … `SQL_PORT` | 7049 / 7048 / 7052 / 7045 / 7085 / 8080 / 11433 | Individual host ports (override the offset). |
| `-Engine` | `ENGINE` | `auto` | `auto` (`docker` if its CLI exists, else `podman`), `docker` or `podman`. `docker` follows its current context (`DOCKER_CONTEXT` / `docker context use`), so Kiri, OrbStack etc. need no option. |
| `-RepoPath` | `REPO_PATH` | `~/.bcvm/MsDyn365Bc.On.Linux` | Use your own clone of the upstream repo. |
| `-RepoRef` | `REPO_REF` | `master` | Branch or tag to fetch when no `-RepoPath` is given. |
| `-BcImage` | `BC_RUNNER_IMAGE` | upstream `bc-runner:latest` | Override the BC image. |
| `-SqlImage` | `BC_SQL_IMAGE` | upstream default | Override the SQL Server image. |
| `-CompanyName` | `COMPANY_NAME` | – | Company for `-ConfigPackages`; created if it doesn't exist. Turns on `-FullTextSearch`. See [Company and configuration packages](#company-and-configuration-packages). |
| `-ConfigPackages` | `CONFIG_PACKAGES` | – | RapidStart packages imported and applied into `-CompanyName` in order: `.rapidstart` files, folders (sorted by name) and `feature:<Id>` steps, one string separated by `;` (or a PowerShell array). |
| `-FullTextSearch` | `FULL_TEXT_SEARCH` (`1`/`0`) | on with `-CompanyName`, else off | SQL Server with Full-Text Search (needed to create a company, and by apps using `OptimizeForTextSearch`). ARM hosts build a CU17-based image once (`bclinuxenvironment/mssql:2022-cu17-fts`, ~1 min); x86 hosts use upstream's `mssql:2022-fts`. Ignored when `-SqlImage` is set. |
| `-SqlMemoryMB` | `MSSQL_MEMORY_LIMIT_MB` | `3072` | SQL Server memory cap. |
| `-PersistDatabase` | `PERSIST_DATABASE` | on | Keep the database in a volume. `-PersistDatabase:$false` uses upstream's in-memory tmpfs database, which is lost when the SQL container stops. |
| `-TimeoutMinutes` | `TIMEOUT_MINUTES` | `45` | Maximum wait for the service tier. |
| `-PublishTimeoutSeconds` | `PUBLISH_TIMEOUT_SECONDS` | `3600` | Maximum time for one extension publish. |
| `-Recreate` | – | – | Remove an existing environment of the same name first (deletes its data). |
| `-Remove` | – | – | Tear the environment down and exit. |

### Example env file

[`example.env`](example.env). Copy it for your own settings; files named `*.local.env` are
git-ignored, so personal copies (with license paths and app lists) stay out of the repo.

```ini
NAME=bc285
# 'latest' (default) = newest public release; or e.g. 28.5, or a full build number.
BC_VERSION=28.5
BC_COUNTRY=w1
BC_TYPE=sandbox

# Optional license, e.g. a partner developer license for ISV apps (relative to this file).
BC_LICENSE_HOST_PATH=./dev.bclicense

# Published in this order (semicolon-separated; files or folders, relative to this file).
APPS=apps/Dependency.app;apps/MyApp.app

# Any other key goes straight to the BC container:
# BC_SERVER_SETTINGS=DisableWriteInsideTryFunctions=false
```

### Running several environments

Give each one its own name and port offset:

```powershell
./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -BcVersion 28.5
./Invoke-BcLinuxEnvironment.ps1 -Name bc290 -BcVersion 29.0 -PortOffset 100   # dev 7149, OData 7148, web 8180, SQL 11533 …
```

On Kiri, skip the ports altogether and use names instead (next section):

```powershell
./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -BcVersion 28.5 -PortlessRouter
./Invoke-BcLinuxEnvironment.ps1 -Name bc290 -BcVersion 29.0 -PortlessRouter
```

### Container names (Kiri)

[Kiri](https://runkiri.com/) gives every container an HTTP name on port 80:
`http://<service>.<project>.kiri.local` (or `.kiri.localhost` when local names are not turned on with
`kiri setup --domains`). A name reaches **exactly one** port of its container. By default the script
publishes all ports on `localhost` as usual, and the web client also gets a name:
`http://bc.<Name>.kiri.local/` (the bc container's port 8080 is labelled for it).

All `*.kiri.local` names resolve to `127.0.0.1`. A URL like `http://bc.bc285.kiri.local:7048` therefore
reaches whatever is **published on localhost** port 7048, from any environment and with any name. Only
port 80 (and 443 with Kiri's HTTPS) is routed by name.

**`-PortlessRouter`** makes an environment fully portless: no host ports are published, and the script
adds a small nginx `router` container that answers one name per endpoint and forwards inside the compose
network:

| Endpoint | Name (environment `bc285`) |
|---|---|
| Web client | `http://bc.bc285.kiri.local/` |
| Dev endpoint (AL publish, symbols) | `http://dev.bc285.kiri.local/BC/dev` |
| OData v4 | `http://odata.bc285.kiri.local/BC/ODataV4` |
| API v2.0 | `http://api.bc285.kiri.local/BC/api/v2.0` |
| Client services (WebSocket) | `ws://client.bc285.kiri.local/BC` |
| SQL Server | no name: names are HTTP only. Add `-SqlPort <port>` to publish just that port. |

Environments created this way never collide on ports and need no `-PortOffset`. The summary at the end
prints the names and the AL `launch.json` values for the dev endpoint:

```json
"server": "http://dev.bc285.kiri.local", "port": 80, "serverInstance": "BC", "authentication": "UserPassword"
```

`-PortlessRouter` needs Kiri; on other engines the script stops and suggests `-PortOffset`.

### Progress and status (people and agents)

Creating an environment takes minutes (much longer with configuration packages), so every run keeps a
machine-readable status that people and agents can watch while it runs:

| Where | What |
|---|---|
| `~/.bcvm/<Name>/www/status.json` | Always written, from the moment creation starts (also before containers exist, e.g. during the SQL image build). Replaced atomically, so a reader never sees half a file. |
| `http://<Name>.kiri.local/api/status` | The same JSON over HTTP, with `-PortlessRouter` (served by the router; CORS enabled). |
| `http://<Name>.kiri.local/` | A small status page (plain HTML, no external files) that polls the API: current step and detail, the services with **Open** / **Copy** buttons (web client, dev endpoint, OData, API, client services, SQL, AL `launch.json` values), step list with durations, and the log tail. |

The script prints the file path when it starts and, with `-PortlessRouter`, the page URL as soon as the
containers are up:

```
  Track progress: http://demo.kiri.local/   (agents: http://demo.kiri.local/api/status)
```

```json
{
  "schema": 1, "name": "demo", "state": "running",
  "startedAt": "2026-11-16T10:49:09Z", "updatedAt": "…", "finishedAt": null,
  "step": "Publishing 3 extension(s)", "detail": "2/3: LS Retail_LS Central_28.2.0.1847.app",
  "error": null,
  "settings": { "bcVersion": "28.5", "country": "w1", "bcType": "sandbox", "apps": 3, "company": null, "configPackages": 0, "portlessRouter": true },
  "links": [ { "name": "Web client", "url": "http://bc.demo.kiri.local/", "kind": "http" },
             { "name": "AL launch.json", "url": "\"server\": \"http://dev.demo.kiri.local\", \"port\": 80, …", "kind": "text" }, … ],
  "steps": [ { "title": "Preparing", "status": "done", "startedAt": "…", "endedAt": "…", "detail": null }, … ],
  "log": [ { "time": "…", "level": "info", "message": "…" }, … ],
  "endpoints": null
}
```

- **`state`**: `running`, then `ready` (with `endpoints` filled from the summary) or `failed` (with
  `error`). A failed run keeps its status until the environment is removed or recreated.
- **`links`** are known from the start (`kind`: `http`, `ws` or `text` for values to copy); they
  respond once `state` is `ready`.
- **`steps`** mirror the console steps; `detail` shows progress inside a long step (boot lines from the
  service tier, app *i*/*n*, package step *i*/*n*). `log` keeps the last 200 lines (`step`, `info`,
  `warning`, `error`).
- The status file appears only after the "already exists" check, so a refused run never overwrites the
  status of an existing environment. `-Remove` deletes it with the rest of `~/.bcvm/<Name>`.

Polling example for an agent:

```bash
until curl -s http://demo.kiri.local/api/status | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s["state"], s["step"], s["detail"] or ""); sys.exit(s["state"] == "running")'; do sleep 10; done
```

---

## Extensions

- Files are published through the dev endpoint (`/BC/dev/apps?SchemaUpdateMode=forcesync`)
  **in the order given**, after the service tier is ready. Each one is installed as part of
  the publish.
- The upload runs **inside the BC container** (copied in with `docker cp`, posted with curl to
  the container's own `localhost:7049`, like upstream's `publish-app.sh`), and the script polls
  for the result. A publish can take minutes, and some engines' port forwarding drops a
  connection that stays silent that long (Kiri: 300 s), which made BC roll the publish back.
- Give the list as **one string separated by `;`**: `-Apps 'a.app;b.app'`, the same as `APPS=`
  in an env file. It works identically from every shell. A PowerShell array
  (`-Apps 'a.app','b.app'`) and `,` as the separator are accepted too. An entry that exists as
  a file is never split, even if its name contains `,` or `;`.
- A folder in `-Apps` contributes its `*.app` files sorted by name.
- If an app fails because one of its dependencies is not installed yet, it is **deferred**
  and retried after the others. Any other failure stops the script and prints BC's error.
- "Already published/installed" answers count as success, using the same rule as upstream
  `scripts/publish-app.sh`, so re-running is safe.
- Runtime packages (`*_runtime.app`) work like normal apps.
- At the end, the script lists every non-Microsoft extension from the automation API and
  warns about any that are published but not installed.

Large apps take a while under emulation: a large ISV app (LS Central 28.2) took 220–300 s on an M-series Mac.

---

## Company and configuration packages

After the extensions, the script can create a company and fill it from RapidStart configuration
packages, for example BC's base data followed by an ISV's demo data:

```powershell
./Invoke-BcLinuxEnvironment.ps1 -Name demo -BcVersion 28.5 -LicenseFile ./dev.bclicense `
    -Apps './apps' -CompanyName 'My Demo' `
    -ConfigPackages './packages/NAV28.0.W1.ENU.EXTENDED.rapidstart;feature:SalesPrices;./packages/isv-demo-data'
```

```ini
# the same in an env file
COMPANY_NAME=My Demo
CONFIG_PACKAGES=packages/NAV28.0.W1.ENU.EXTENDED.rapidstart;feature:SalesPrices;packages/isv-demo-data
```

- **Order** is the order given. A folder contributes its `*.rapidstart` files sorted by name
  (`NO-02` < `NO-02A` < `NO-03`); list files one by one when their names don't sort into the needed
  order.
- **`feature:<Id>`** enables a Feature Management feature at that point, with its data update, for
  example `feature:SalesPrices` ("New sales pricing experience") before packages that load price lists.
- **Each package** is imported and then applied through the automation API. An existing package with
  the same code in that company is replaced. Record errors from the apply step (e.g. the 4 known
  item-category errors of BC's `EXTENDED` package) are reported as warnings and listed in BC under
  *Configuration Packages*; an import or apply that fails as a whole stops the script.
- **Company creation needs SQL Full-Text Search**, so `-CompanyName` turns on `-FullTextSearch`. On
  ARM the first run builds the SQL image (about a minute); later runs reuse it.
- **Packages are big:** BC's `EXTENDED` package (403 tables, ~16,000 records) took about 5 min to import
  and 5–6 min to apply under emulation.

Things the script does so that packages work on the Linux service tier (details in
[docs/ROADMAP.md](docs/ROADMAP.md)):

- It enables **background tasks**, which package import and apply (and the job queue) run on: a
  `Kernel32.dll` link for the task runner, and no Windows Security ID on the login user. The first
  run with packages restarts the service tier once for the latter.
- It uploads a copy of each package with **`MinCountForAsyncImport`** raised, because BC's parallel
  table import uses named memory-mapped files, which .NET doesn't support on Linux. Tables are then
  imported one after another.
- All API calls run **inside the BC container**, so slow calls aren't cut off by the engine's port
  forwarding or name router.

Retail images and other UI-only steps are not covered.

---

## What the script does

1. **Settings:** merges defaults, env file, `BCVM_*` variables and parameters.
2. **Engine:** takes the `docker` CLI (skipping dangling links left by an uninstalled Docker
   Desktop; Kiri's `~/.kiri/bin/docker` is found even when it is not on `PATH`), else `podman`.
   One `info` call checks the engine is reachable and reads its architecture; one
   `compose version` call checks compose.
3. **Checks:** the app and license files exist, all host ports are free, and no
   environment of that name exists (unless `-Recreate`).
   With `-BcVersion latest` (the default) it then reads Microsoft's public artifact index
   for the sandbox/onprem type and country, and uses the newest released build number.
4. **Upstream repo:** clones MsDyn365Bc.On.Linux into `~/.bcvm/MsDyn365Bc.On.Linux` on
   first use, or downloads a zip if git is missing. Later runs fast-forward it (`git pull
   --ff-only`), and an offline run keeps the cached copy.
5. **Compose files:** writes two per-environment files in `~/.bcvm/<Name>/`:
   - `compose.env`: all settings, using upstream's variable names, passed with `--env-file`
   - `compose.override.yml`: what upstream does not offer as variables:
     - `restart: unless-stopped`
     - extra container environment
     - a persistent `sql-data` volume, replacing upstream's tmpfs (SQL runs as root so
       it can write to the fresh volume)
     - a SQL image override, if `-SqlImage` is set

   The stack is `docker-compose.yml` + (`docker-compose.macos.yml` when emulated) +
   `compose.override.yml`. The file list is saved in `compose-files.txt` so `-Remove`
   uses the same set.
6. **Emulation (ARM hosts):** adds upstream's macOS overlay, which pins SQL Server 2022
   CU17 because later CUs crash under Rosetta. It also sets
   `DOTNET_INTERNAL_ThreadSuspendInjection=0` and `DOTNET_GCHeapCount=2` on the BC
   container. Without them the service tier crashes under Rosetta with
   `rosetta error: rt_tgsigqueueinfo failed in pend_signal` (exit 133). Both can be
   overridden with `-ContainerEnv`.
7. **Start:** `compose config` (validation), `compose pull --ignore-pull-failures`, then
   `compose up -d`.
8. **Wait:** polls until the container's `/tmp/bc-ready` marker exists **and** OData
   `/Company` answers with the configured login. It prints upstream's boot progress lines
   and fails fast, showing the last 60 log lines, if the container stops.
9. **Background tasks:** links `Kernel32.dll` for the task runner and clears the login user's
   Windows Security ID, so the task scheduler can run tasks (see
   [Company and configuration packages](#company-and-configuration-packages)).
10. **Extensions:** see above.
11. **Company and packages** (optional): creates `-CompanyName` and imports and applies
    `-ConfigPackages` in order.
12. **Summary:** endpoints, login, installed extensions, company, and the full compose command for
    managing the stack.

On first boot the container downloads the BC artifacts (about 2 GB), restores the demo
database and starts the service tier. The upstream entrypoint also publishes the Microsoft
test toolkit and its own *Test Runner Extension*, so those appear in the extension list.

---

## Managing an environment

The summary prints the exact compose command. For `bc285` it is:

```bash
docker compose -p bc285 \
  -f ~/.bcvm/MsDyn365Bc.On.Linux/docker-compose.yml \
  -f ~/.bcvm/MsDyn365Bc.On.Linux/docker-compose.macos.yml \
  -f ~/.bcvm/bc285/compose.override.yml \
  --env-file ~/.bcvm/bc285/compose.env  <ps|logs -f bc|stop|start|restart bc>
```

- **Stop / start:** `stop` and `start` keep everything, including installed extensions and
  data (verified: after a full stop/start the tier was back in about 100 s with all apps
  installed). On a warm start the upstream entrypoint republishes its test toolkit, and BC
  logs harmless "duplicate package ID" messages for it.
- **Logs:** `docker logs -f bc285-bc-1`. The web client log is
  `docker exec bc285-bc-1 tail -f /tmp/webclient.log`.
- **Remove:** `./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -Remove` runs `compose down -v`, then
  removes anything still labelled with the project and deletes `~/.bcvm/bc285`.
- **Recreate:** add `-Recreate` to the create command.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `The docker credential helper fails` / `error getting credentials … docker-credential-desktop: executable file not found` | `credsStore` in `~/.docker/config.json` names a helper that is gone (typically `desktop` after switching from Docker Desktop to Kiri or another engine) or can't read the keychain from a non-interactive session. The images are public: remove the `credsStore` line, or fix the helper. The script carries on with cached images if it can. |
| `The container engine is not reachable … The docker context is 'desktop-linux'` | The current docker context points at an engine that isn't running or no longer exists. Start it, or switch, e.g. `docker context use kiri` (Kiri: `kiri setup --use`). |
| `compose up failed … pull access denied` / image not found | The runner image couldn't be pulled and isn't cached. The script never builds it from source (`--no-build`); fix the pull (see above) or `-BcImage`. If an earlier run of another tool built `bc-runner:latest` locally, `docker rmi ghcr.io/aldevtools/msdyn365bc.on.linux/bc-runner:latest` and pull again. |
| `Host port N is already in use` | Use `-PortOffset` or the individual port parameters. |
| BC container exits with code 133 and `rosetta error` in the logs | Emulation without the .NET fixes. They are applied automatically on ARM; if you override `-ContainerEnv`, keep `DOTNET_INTERNAL_ThreadSuspendInjection=0`. |
| ISV apps fail to publish with license / object-range errors | Pass the partner license with `-LicenseFile` / `BC_LICENSE_HOST_PATH`. |
| `Text optimized index cannot be created … Full-Text Search component is not installed` | An app (or creating a new company) needs SQL Full-Text Search: add `-FullTextSearch` (recreate the environment, the SQL image changes). |
| Timeout waiting for BC | `docker logs <Name>-bc-1`. A first boot under emulation takes 3–5 min; slow artifact downloads add to that. |

---

## Validation

Validated end to end on macOS (Apple Silicon, Docker Desktop 4.94, Compose v5.5.1):
BC sandbox 28.5.54151.58046 W1, web client, a partner license, and three ISV apps
published in dependency order (LS Central System App runtime → LS Central → LS Central for
pharmacies).
Total 9 min:

- 3 min to a ready service tier, including the artifact download
- about 6 min to publish the three apps

Persistence across stop/start was also verified.

**Not yet tested:** Windows, Linux, Podman, and `-Remove` end to end. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Files

| Path | Purpose |
|---|---|
| `Invoke-BcLinuxEnvironment.ps1` | The script. `Get-Help ./Invoke-BcLinuxEnvironment.ps1 -Detailed` for built-in help. |
| `example.env` | Example env file. Personal copies: `*.local.env` (git-ignored). |
| `docs/ROADMAP.md` | Findings, work in progress and backlog. |
| `apps/` | *Local only, git-ignored.* Your extensions (`*.app`). |
| `*.bclicense` | *Local only, git-ignored.* License files, e.g. the partner developer license. |
| `*.rapidstart` | *Local only, git-ignored.* Configuration packages. |
| `experiments/` | *Local only, git-ignored.* Scratch space for prototypes. |
| `~/.bcvm/` | Cached upstream repo and per-environment state (outside the project). |
