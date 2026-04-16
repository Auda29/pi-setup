# Pi Setup Stack

## TL;DR

- Run `scripts/install-pi-stack.ps1` if you want to install the Pi stack **into the repo/folder you run it from**.
- Run `scripts/install-pi-stack-global.ps1` if you want a **global Pi setup** for all repos/editors.
- Start Pi on Windows via `scripts/start-pi.ps1` to get the recommended Python UTF-8 environment variables.
- If something breaks, use `scripts/repair-pi-stack.ps1`.
- If you want to remove the local setup again, use `scripts/uninstall-pi-stack.ps1`.

Quick start for the current repo/folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\start-pi.ps1
```

Quick global setup:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack-global.ps1
powershell -ExecutionPolicy Bypass -File $HOME\.pi-stack\scripts\start-pi.ps1
```

## Overview

Robust Windows setup for your Pi stack with these components:

There are now two variants:

- **project-local in the folder/repo where you run the installer** via `scripts/install-pi-stack.ps1`
- **global across repos/editors** via `scripts/install-pi-stack-global.ps1`

Stack components:

- `@mariozechner/pi-coding-agent`
- `pi-subagents`
- `pi-mcp-adapter`
- `pi-lens`
- `pi-web-access`
- `mempalace-pi`
- optionally later `pi-twincat-ads`

Goal: a setup that works as reproducibly as possible on both **fresh Windows systems** and machines with an **existing Pi installation**.

## What the setup does

`scripts/install-pi-stack.ps1` does the following in the folder/repo you run it from:

1. checks whether it is running on Windows
2. installs missing prerequisites via `winget` when possible
   - Node.js LTS
   - Git for Windows
   - optional Python 3
3. installs or updates `@mariozechner/pi-coding-agent` globally
4. installs the Pi extensions locally in `.pi-packages`
5. writes a robust `.pi/settings.json`
   - `npmCommand`
   - `shellPath`
   - `packages`
   - `sessionDir`
6. creates or updates an `AGENTS.md` with tool guidance for coding agents
7. creates backups of existing settings
8. creates a Windows start script: `scripts/start-pi.ps1`
9. writes an install log to `.pi/logs/`

## Why this approach?

On Windows, the direct path via `pi install npm:...` is not always the least painful one. This setup therefore installs the extensions **locally via npm** and wires them into `.pi/settings.json` **via local package paths**.

For your use case, that is more stable, more reproducible, and easier to debug.

## Requirements

Recommended:

- Windows 11 or current Windows 10
- PowerShell 5.1+ or PowerShell 7+
- `winget` available
- internet access for `winget` and `npm`

If `winget` is missing, you must install missing prerequisites manually.

## Quick start

### Project-local in the current repo/folder

Inside the target project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1
```

Then start Pi with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-pi.ps1
```

### Global across repos/editors

If you want one central Pi stack that is available via the global Pi settings:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack-global.ps1
```

Optional with your own target folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack-global.ps1 -InstallRoot C:\Tools\pi-stack
```


## Recommended way to start Pi on Windows

Prefer starting Pi via this script:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-pi.ps1
```

This sets the following for the session:

- `PYTHONUTF8=1`
- `PYTHONIOENCODING=utf-8`

That is especially helpful for `mempalace-pi` on Windows.

## Installer options

### Standard installation

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1
```

### Require Python

If you want `mempalace-pi` to be prepared cleanly right away:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1 -RequirePython
```

### Use latest package versions instead of pinned versions

By default, this setup uses pinned versions for better reproducibility.

If you intentionally want to use `latest` instead:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1 -UseLatestPackageVersions
```

### Install local `pi-twincat-ads`

As soon as your package exists locally:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1 `
  -IncludeTwinCATAds `
  -TwinCATAdsSource ..\pi-twincat-ads
```

## Exit codes

The install script intentionally returns simple exit codes:

- `0` = success
- `1` = error during installation or validation

Example for CI or wrapper scripts:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installation failed"
}
```

## Logging

Each run writes a log to:

```text
.pi/logs/install-YYYYMMDD-HHMMSS.log
```

If something goes wrong, check that first.

## Retry strategy

The script uses retries for the usual flaky operations:

- `winget install`
- `npm install -g @mariozechner/pi-coding-agent`
- `npm install` in `.pi-packages`
- optional `npm install` for `pi-twincat-ads`

This makes it more likely to survive:

- short network issues
- registry hiccups
- temporary npm or winget outages

## Important files

- `scripts/install-pi-stack.ps1` - bootstrap/installer for the current repo or folder
- `scripts/install-pi-stack-global.ps1` - installs a global Pi stack and updates the global Pi settings
- `scripts/start-pi.ps1` - recommended Windows start script
- `scripts/repair-pi-stack.ps1` - repair an existing setup
- `scripts/uninstall-pi-stack.ps1` - remove the project-local setup
- `.pi-packages/package.json` - local stack definition
- `.pi/settings.json` - project-local Pi configuration
- `.pi/backups/` - backups of existing settings
- `.pi/logs/` - install/repair/uninstall logs
- `AGENTS.md` - agent guidance for installed Pi tools

## Installed packages

Pinned by default:

- `pi-subagents` `0.14.1`
- `pi-mcp-adapter` `2.4.0`
- `pi-lens` `3.8.26`
- `pi-web-access` `0.10.6`
- `mempalace-pi` `0.2.0`

## What happens if Pi is already installed?

That is exactly what the script is built for:

- existing `pi` is not blindly assumed, but updated
- existing `.pi/settings.json` is backed up before being overwritten
- existing `.pi-packages/package.json` is extended instead of being bluntly destroyed
- package paths are deduplicated

## Common issues

### 1. `winget` is missing

Then you have to install Node.js, Git for Windows, and optionally Python manually.

### 2. `pi` is not found after global npm install

Typically check:

- `%APPDATA%\npm` in PATH
- whether `pi.cmd` exists under `%APPDATA%\npm`

The start script already includes a fallback to `%APPDATA%\npm\pi.cmd`.

### 3. Git Bash is missing

Pi needs a Bash shell on Windows. The script therefore tries to install Git for Windows and then sets `shellPath` in `.pi/settings.json`.

### 4. Python or encoding issues with `mempalace-pi`

Always start Pi via:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-pi.ps1
```

## NPM / Pi wiring

This repo uses **local package paths** in `.pi/settings.json`, for example:

```json
{
  "packages": [
    "../.pi-packages/node_modules/pi-subagents"
  ]
}
```

That makes the stack project-local, versionable, and easier to understand.

## Global installer

`scripts/install-pi-stack-global.ps1` installs the shared Pi packages into a central folder and also updates the global Pi settings under `%USERPROFILE%\.pi\agent\settings.json`.

The default target is `%USERPROFILE%\.pi-stack`. You can change the target via `-InstallRoot`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack-global.ps1 -InstallRoot C:\Tools\pi-stack
```


Supported extra options mostly match the normal installer:

- `-RequirePython`
- `-UseLatestPackageVersions`
- `-IncludeTwinCATAds -TwinCATAdsSource <path>`

The target folder will contain, among other things:

- `.pi\settings.json`
- `.pi-packages\package.json`
- `scripts\start-pi.ps1`
- `README-pi-stack.txt`

The global installer also writes shared agent guidance to:

- `%USERPROFILE%\.pi\agents\AGENTS.md`

## Complete global workflow example

Example: create a global Pi stack under `C:\Tools\pi-stack`, verify the generated files, and start Pi.

### 1. Run the global installer

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack-global.ps1 -InstallRoot C:\Tools\pi-stack
```

### 2. Inspect the generated files

```powershell
Get-ChildItem C:\Tools\pi-stack
Get-ChildItem C:\Tools\pi-stack\scripts
Get-Content C:\Tools\pi-stack\README-pi-stack.txt
```

### 3. Start Pi from the global install folder

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\pi-stack\scripts\start-pi.ps1
```

### 4. Optional: install with Python required and latest package versions

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack-global.ps1 `
  -InstallRoot C:\Tools\pi-stack `
  -RequirePython `
  -UseLatestPackageVersions
```

### 5. Optional: include a local `pi-twincat-ads`

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack-global.ps1 `
  -InstallRoot C:\Tools\pi-stack `
  -IncludeTwinCATAds `
  -TwinCATAdsSource ..\pi-twincat-ads
```

## Repair and uninstall

### Repair

If a setup is half-broken, dependencies are missing, or local npm artifacts are corrupted:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\repair-pi-stack.ps1
```

The local installer also writes or updates `AGENTS.md` in the target repo/folder.

The repair script targets the repo/folder you run it from. You can also point it at a specific repo:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\repair-pi-stack.ps1 -ProjectRoot C:\path\to\repo
```

With a hard reset of local npm artifacts:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\repair-pi-stack.ps1 -ForceCleanNodeModules
```

With local `pi-twincat-ads`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\repair-pi-stack.ps1 `
  -IncludeTwinCATAds `
  -TwinCATAdsSource ..\pi-twincat-ads
```

### Uninstall

Remove the project-local Pi stack:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-pi-stack.ps1
```

The uninstall script targets the repo/folder you run it from. You can also point it at a specific repo:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-pi-stack.ps1 -ProjectRoot C:\path\to\repo
```

Also remove global Pi:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-pi-stack.ps1 -RemoveGlobalPi
```

Keep settings, logs, or backups:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-pi-stack.ps1 -KeepSettings -KeepLogs -KeepBackups
```

Both scripts write logs to `.pi/logs/`.

## License

No license has been defined in this repository yet.

If you plan to publish or share this setup, add a license file and make the intended usage explicit. Typical choices are:

- `MIT` for a very permissive setup
- `Apache-2.0` if you want an explicit patent grant
- `GPL-3.0` if you want copyleft requirements

Until a license is added, treat the repository as "all rights reserved" by default.

## Support

This repository currently does not define a formal support channel.

A practical lightweight support model would be:

- use GitHub Issues for bug reports and setup problems
- use Discussions for questions and ideas
- include the relevant log from `.pi/logs/` when reporting an installation issue
- mention your Windows version, PowerShell version, and whether `winget`, `node`, `npm`, `git`, and `python` are available

When reporting problems, it helps to include:

- the exact command you ran
- the full error message
- the log file path
- whether you used the project-local or global installer
- whether `-RequirePython`, `-UseLatestPackageVersions`, or `-IncludeTwinCATAds` was used

## Contributing

Contributions are welcome.

Suggested workflow:

1. fork the repository
2. create a feature branch
3. keep changes focused and small
4. test the affected PowerShell scripts locally
5. update `README.md` when behavior or flags change
6. open a pull request with a short explanation of the change

Good contribution candidates:

- better Windows edge-case handling
- clearer diagnostics and log output
- CI validation for the scripts
- optional support for additional Pi packages
- documentation improvements and troubleshooting notes

## Reasonable next steps

If you want, the next useful additions could be:

- a meta-package for your complete stack
- a CI check for the setup
- automatic checks for `pi-twincat-ads`
