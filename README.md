# bclinuxenvironment: Business Central environments in Docker or Podman

`Invoke-BcLinuxEnvironment.ps1` creates a Microsoft Dynamics 365 Business Central environment in a
local container engine. It then installs your extensions (`.app` files) in the order you
give them. One PowerShell script works the same way on Windows, Linux and macOS.

It is built on [MsDyn365Bc.On.Linux](https://github.com/aldevtools/MsDyn365Bc.On.Linux),
which runs the unmodified BC service tier on Linux. The script uses that project's
supported workflow (`docker compose up`) and adds what the upstream workflow leaves to you:

- picks the container engine and compose command
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
bclinux -Name bc285de -BcVersion 28.5 -Country de -Apps ./apps '-WebClient:$false'
bclinux -Name bc290 -Remove
```

Quoting in zsh/bash:

- Line continuation is `\` (PowerShell uses a backtick).
- Put **single quotes** around anything with spaces, and around `'-WebClient:$false'` /
  `'-PersistDatabase:$false'`. Without them the shell expands `$false` to an empty string.
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

Use double quotes for values with spaces (`-Apps "a.app;b.app"`). `-WebClient:$false` needs no
quoting in cmd. Line continuation is `^`. Not tested yet.

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
| Docker **or** Podman, running | Detected automatically; Docker is tried first. Override with `-Engine`. |
| Compose v2 | `docker compose`, `podman compose` (with `docker-compose` as its provider) or a standalone `docker-compose`. |
| `git` (optional) | Fetches the upstream repo. Without git, the script downloads a zip from GitHub instead. |
| Memory | About 6 GB free for the containers (SQL 3 GB + BC 2–3 GB). On Docker Desktop / podman machine, give the VM 12–16 GB. |
| Disk | About 5 GB per environment (artifacts, service tier, database), plus about 2 GB of images. |

### Apple Silicon / ARM hosts

The BC runner image is `linux/amd64` only, so on ARM it runs under emulation. The script
detects this and applies the needed fixes automatically (see
[What the script does](#what-the-script-does)).

- **Docker Desktop:** enable *Use Rosetta for x86_64/amd64 emulation* in Settings → General.
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
| `-PortOffset` | `PORT_OFFSET` | `0` | Added to every default port, so several environments can run side by side. |
| `-DevPort` `-ODataPort` `-ApiPort` `-MgmtPort` `-ClientPort` `-WebClientPort` `-SqlPort` | `BC_DEV_PORT` … `SQL_PORT` | 7049 / 7048 / 7052 / 7045 / 7085 / 8080 / 11433 | Individual host ports (override the offset). |
| `-Engine` | `ENGINE` | `auto` | `auto`, `docker` or `podman`. |
| `-RepoPath` | `REPO_PATH` | `~/.bcvm/MsDyn365Bc.On.Linux` | Use your own clone of the upstream repo. |
| `-RepoRef` | `REPO_REF` | `master` | Branch or tag to fetch when no `-RepoPath` is given. |
| `-BcImage` | `BC_RUNNER_IMAGE` | upstream `bc-runner:latest` | Override the BC image. |
| `-SqlImage` | `BC_SQL_IMAGE` | upstream default | Override the SQL Server image (e.g. one with Full-Text Search, see [docs/ROADMAP.md](docs/ROADMAP.md)). |
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

---

## Extensions

- Files are published through the dev endpoint (`/BC/dev/apps?SchemaUpdateMode=forcesync`)
  **in the order given**, after the service tier is ready. Each one is installed as part of
  the publish.
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

## What the script does

1. **Settings:** merges defaults, env file, `BCVM_*` variables and parameters.
2. **Engine:** finds a running Docker or Podman. `docker` may be podman's alias; it is
   detected through `docker --version`. Then it finds a compose command.
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
9. **Extensions:** see above.
10. **Summary:** endpoints, login, installed extensions, and the full compose command for
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
| `Pull failed, using the image already present locally … keychain cannot be accessed` | On macOS the Docker CLI's credential helper can't read the keychain from a non-interactive session. The images are public. The script carries on with cached images; to refresh, run `docker pull ghcr.io/aldevtools/msdyn365bc.on.linux/bc-runner:latest` from an interactive terminal. |
| `No running container engine found` | Start Docker Desktop, or run `podman machine start`. |
| `Host port N is already in use` | Use `-PortOffset` or the individual port parameters. |
| BC container exits with code 133 and `rosetta error` in the logs | Emulation without the .NET fixes. They are applied automatically on ARM; if you override `-ContainerEnv`, keep `DOTNET_INTERNAL_ThreadSuspendInjection=0`. |
| ISV apps fail to publish with license / object-range errors | Pass the partner license with `-LicenseFile` / `BC_LICENSE_HOST_PATH`. |
| `Text optimized index cannot be created … Full-Text Search component is not installed` | An app (or creating a new company) needs SQL Full-Text Search. Use an FTS-capable SQL image via `-SqlImage`; see [docs/ROADMAP.md](docs/ROADMAP.md) for the ARM build. |
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
