[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $PWD 'pi-stack'),
    [switch]$IncludeTwinCATAds,
    [string]$TwinCATAdsSource,
    [switch]$RequirePython,
    [switch]$UseLatestPackageVersions
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$IsWindowsPlatform = if (Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue) {
    [bool]$IsWindows
}
else {
    ($PSVersionTable.PSEdition -eq 'Desktop') -or ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
}

$TranscriptStarted = $false
$ScriptExitCode = 0
$ResolvedInstallRoot = $null
$StandaloneScriptPath = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $PSCommandPath }

$PinnedVersions = [ordered]@{
    'mempalace-pi'   = '0.2.0'
    'pi-lens'        = '3.8.26'
    'pi-mcp-adapter' = '2.4.0'
    'pi-subagents'   = '0.14.1'
    'pi-web-access'  = '0.10.6'
}

$PackageNames = @($PinnedVersions.Keys)

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[info] $Message" -ForegroundColor DarkGray
}

function Write-ErrorLine {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[error] $Message" -ForegroundColor Red
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $combined = @($machinePath, $userPath) -join ';'
    if (-not [string]::IsNullOrWhiteSpace($combined)) {
        $env:Path = $combined
    }
}

function Get-CommandPathSafe {
    param([Parameter(Mandatory = $true)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory
    )

    if ($WorkingDirectory) { Push-Location $WorkingDirectory }
    try {
        Write-Info ("Run: " + $FilePath + ' ' + ($Arguments -join ' '))
        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "Command failed ($exitCode): $FilePath $($Arguments -join ' ')"
        }
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 4
    )

    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            Write-Info "$Description (attempt $attempt/$MaxAttempts)"
            & $Action
            return
        }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warning "$Description failed: $($_.Exception.Message)"
            Write-Info "Waiting $DelaySeconds seconds before the next attempt ..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $winget = Get-CommandPathSafe -Name 'winget'
    if (-not $winget) {
        throw "'$DisplayName' is missing and winget is not available. Please install it manually."
    }

    Write-Step "Installing $DisplayName via winget"
    Invoke-WithRetry -Description "winget install $PackageId" -Action {
        Invoke-External -FilePath $winget -Arguments @(
            'install', '--id', $PackageId, '--exact', '--silent',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        )
    } -MaxAttempts 2 -DelaySeconds 5
    Refresh-ProcessPath
}

function Ensure-Command {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$WingetPackageId,
        [string]$DisplayName = $Name,
        [switch]$Optional
    )

    if (Test-CommandExists -Name $Name) {
        return (Get-CommandPathSafe -Name $Name)
    }

    if ($WingetPackageId) {
        try {
            Invoke-WingetInstall -PackageId $WingetPackageId -DisplayName $DisplayName
        }
        catch {
            if ($Optional) {
                Write-Warning $_.Exception.Message
                return $null
            }
            throw
        }

        if (Test-CommandExists -Name $Name) {
            return (Get-CommandPathSafe -Name $Name)
        }
    }

    if ($Optional) {
        Write-Warning "'$DisplayName' was not found."
        return $null
    }

    throw "'$DisplayName' was not found."
}

function Save-JsonObject {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $json = $Data | ConvertTo-Json -Depth 100
    Set-Content -LiteralPath $Path -Value ($json + "`n") -Encoding UTF8
}

function Get-NpmExecutable {
    $npmCmd = Get-CommandPathSafe -Name 'npm.cmd'
    if ($npmCmd) { return $npmCmd }
    $npm = Get-CommandPathSafe -Name 'npm'
    if ($npm) { return $npm }
    return $null
}

function Get-PiExecutable {
    $pi = Get-CommandPathSafe -Name 'pi'
    if ($pi) { return $pi }

    $appData = [Environment]::GetFolderPath('ApplicationData')
    $piCmd = Join-Path $appData 'npm\pi.cmd'
    if (Test-Path -LiteralPath $piCmd) {
        return $piCmd
    }

    return $null
}

function Get-GitBashPath {
    $candidates = @(
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files (x86)\Git\bin\bash.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $bash = Get-CommandPathSafe -Name 'bash'
    if ($bash) { return $bash }
    return $null
}

function Get-DependencyMap {
    $dependencies = [ordered]@{}
    foreach ($name in $PackageNames) {
        $dependencies[$name] = if ($UseLatestPackageVersions) { 'latest' } else { $PinnedVersions[$name] }
    }
    return $dependencies
}

function Test-PackageInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$PackagesDir,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    $packagePath = Join-Path $PackagesDir ("node_modules\$PackageName")
    return (Test-Path -LiteralPath $packagePath)
}

function Assert-PackageInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$PackagesDir,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    if (-not (Test-PackageInstalled -PackagesDir $PackagesDir -PackageName $PackageName)) {
        throw "Package missing after npm install: $PackageName"
    }
}

try {
    if (-not $IsWindowsPlatform) {
        throw 'This standalone script is intended for Windows.'
    }

    Ensure-Directory -Path $InstallRoot
    $ResolvedInstallRoot = (Resolve-Path -LiteralPath $InstallRoot).Path

    $PiDir = Join-Path $ResolvedInstallRoot '.pi'
    $PackagesDir = Join-Path $ResolvedInstallRoot '.pi-packages'
    $ScriptsDir = Join-Path $ResolvedInstallRoot 'scripts'
    $LogsDir = Join-Path $PiDir 'logs'
    $BackupsDir = Join-Path $PiDir 'backups'
    $SettingsPath = Join-Path $PiDir 'settings.json'
    $PackagesManifestPath = Join-Path $PackagesDir 'package.json'
    $StartScriptPath = Join-Path $ScriptsDir 'start-pi.ps1'
    $ReadmePath = Join-Path $ResolvedInstallRoot 'README-pi-stack.txt'
    $InstallLogPath = Join-Path $LogsDir ("standalone-install-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

    Ensure-Directory -Path $PiDir
    Ensure-Directory -Path $PackagesDir
    Ensure-Directory -Path $ScriptsDir
    Ensure-Directory -Path $LogsDir
    Ensure-Directory -Path $BackupsDir

    try {
        Start-Transcript -Path $InstallLogPath -Force | Out-Null
        $TranscriptStarted = $true
    }
    catch {
        Write-Warning "Could not start transcript: $($_.Exception.Message)"
    }

    Write-Info "Install target: $ResolvedInstallRoot"
    Write-Info "Install log: $InstallLogPath"

    Write-Step 'Checking and installing prerequisites'
    $nodePath = Ensure-Command -Name 'node' -WingetPackageId 'OpenJS.NodeJS.LTS' -DisplayName 'Node.js LTS'
    [void](Ensure-Command -Name 'npm' -WingetPackageId 'OpenJS.NodeJS.LTS' -DisplayName 'npm')
    $npmExe = Get-NpmExecutable
    if (-not $npmExe) {
        throw 'Could not resolve npm.'
    }

    Write-Host "node: $(& $nodePath --version)"
    Write-Host "npm:  $(& $npmExe --version)"

    $gitBashPath = Get-GitBashPath
    if (-not $gitBashPath) {
        [void](Ensure-Command -Name 'git' -WingetPackageId 'Git.Git' -DisplayName 'Git for Windows')
        $gitBashPath = Get-GitBashPath
    }

    if (-not $gitBashPath) {
        throw 'No bash shell found. Pi needs Git Bash or another bash.exe on Windows.'
    }
    Write-Host "bash: $gitBashPath"

    $pythonPath = Get-CommandPathSafe -Name 'py'
    if (-not $pythonPath) {
        $pythonPath = Get-CommandPathSafe -Name 'python'
    }
    if (-not $pythonPath) {
        $pythonPath = Ensure-Command -Name 'py' -WingetPackageId 'Python.Python.3.12' -DisplayName 'Python 3' -Optional:(-not $RequirePython)
        if (-not $pythonPath) {
            $pythonPath = Get-CommandPathSafe -Name 'python'
        }
    }

    if ($RequirePython -and -not $pythonPath) {
        throw 'Python is required but could not be installed or found.'
    }

    if ($pythonPath) {
        try {
            Write-Host "python: $(& $pythonPath --version 2>&1)"
        }
        catch {
            Write-Warning "Python was found, but its version could not be read: $($_.Exception.Message)"
        }
    }
    else {
        Write-Warning 'Python was not found. mempalace-pi may require a manual Python installation later.'
    }

    Write-Step 'Installing or updating pi-coding-agent globally'
    Invoke-WithRetry -Description 'npm install -g @mariozechner/pi-coding-agent' -Action {
        Invoke-External -FilePath $npmExe -Arguments @('install', '-g', '@mariozechner/pi-coding-agent', '--no-fund', '--no-audit')
    } -MaxAttempts 3 -DelaySeconds 5
    Refresh-ProcessPath

    $piExe = Get-PiExecutable
    if (-not $piExe) {
        throw 'pi was not found after the global npm install.'
    }
    Write-Host "pi:   $(& $piExe --version)"

    Write-Step 'Creating local package manifest'
    $manifest = [ordered]@{
        name         = 'pi-setup-stack'
        private      = $true
        description  = 'Local Pi stack for this project'
        dependencies = (Get-DependencyMap)
    }
    Save-JsonObject -Path $PackagesManifestPath -Data $manifest

    Write-Step 'Installing local Pi packages via npm'
    Invoke-WithRetry -Description 'npm install for .pi-packages' -Action {
        Invoke-External -FilePath $npmExe -WorkingDirectory $PackagesDir -Arguments @('install', '--no-fund', '--no-audit')
    } -MaxAttempts 3 -DelaySeconds 5

    foreach ($packageName in $PackageNames) {
        Assert-PackageInstalled -PackagesDir $PackagesDir -PackageName $packageName
    }

    if ($IncludeTwinCATAds) {
        if ([string]::IsNullOrWhiteSpace($TwinCATAdsSource)) {
            throw 'If -IncludeTwinCATAds is set, -TwinCATAdsSource must also be provided.'
        }

        $resolvedTwinCATAds = (Resolve-Path -LiteralPath $TwinCATAdsSource -ErrorAction Stop).Path
        Write-Step 'Installing pi-twincat-ads from local path'
        Invoke-WithRetry -Description 'npm install pi-twincat-ads' -Action {
            Invoke-External -FilePath $npmExe -WorkingDirectory $PackagesDir -Arguments @('install', $resolvedTwinCATAds, '--no-fund', '--no-audit')
        } -MaxAttempts 3 -DelaySeconds 5
        Assert-PackageInstalled -PackagesDir $PackagesDir -PackageName 'pi-twincat-ads'
    }

    Write-Step 'Writing .pi/settings.json'
    $packagePaths = @(
        '../.pi-packages/node_modules/pi-subagents',
        '../.pi-packages/node_modules/pi-mcp-adapter',
        '../.pi-packages/node_modules/pi-lens',
        '../.pi-packages/node_modules/pi-web-access',
        '../.pi-packages/node_modules/mempalace-pi'
    )
    if ($IncludeTwinCATAds) {
        $packagePaths += '../.pi-packages/node_modules/pi-twincat-ads'
    }

    $settings = [ordered]@{
        npmCommand = @($npmExe)
        shellPath  = $gitBashPath
        packages   = $packagePaths
        sessionDir = '.pi/sessions'
    }
    Save-JsonObject -Path $SettingsPath -Data $settings

    Write-Step 'Writing start script'
    $startScript = @"
param(
    [Parameter(ValueFromRemainingArguments = `$true)]
    [string[]]`$PiArgs
)

`$ErrorActionPreference = 'Stop'
`$env:PYTHONUTF8 = '1'
`$env:PYTHONIOENCODING = 'utf-8'

`$ScriptDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$ProjectRoot = Split-Path -Parent `$ScriptDir
Set-Location `$ProjectRoot

`$piCmd = Get-Command 'pi' -ErrorAction SilentlyContinue
`$piCmdPath = if (`$piCmd) { `$piCmd.Source } else { `$null }
if (-not `$piCmdPath) {
    `$piFallback = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'npm\pi.cmd'
    if (Test-Path -LiteralPath `$piFallback) {
        `$piCmdPath = `$piFallback
    }
}

if (-not `$piCmdPath) {
    throw 'pi was not found. Please run install-pi-stack-standalone.ps1 first.'
}

& `$piCmdPath @PiArgs
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $StartScriptPath -Value $startScript -Encoding UTF8

    Write-Step 'Writing standalone README'
    $readme = @'
Pi Setup Stack
==============

This standalone Pi stack has been set up successfully.

Installation directory:
__INSTALL_ROOT__

What is included
----------------

- global @mariozechner/pi-coding-agent
- local Pi extensions in .pi-packages
- project-local Pi settings in .pi\settings.json
- Windows start script in scripts\start-pi.ps1
- install logs in .pi\logs\

Important files
---------------

- .pi\settings.json
- .pi-packages\package.json
- scripts\start-pi.ps1
- .pi\logs\

Recommended start command
-------------------------

powershell -ExecutionPolicy Bypass -File .\scripts\start-pi.ps1

Why use the start script?
-------------------------

The start script sets these environment variables for the current session:

- PYTHONUTF8=1
- PYTHONIOENCODING=utf-8

That is especially useful on Windows, in particular for mempalace-pi.

If something goes wrong
-----------------------

1. Check the latest file in .pi\logs\
2. Verify that pi, node, npm, and git are available
3. Confirm that Git Bash exists and that .pi\settings.json points to a valid bash.exe
4. If Python-based features fail, verify that Python is installed and callable via py or python

Installed local packages
------------------------

- pi-subagents
- pi-mcp-adapter
- pi-lens
- pi-web-access
- mempalace-pi
'@
    $readme = $readme.Replace('__INSTALL_ROOT__', $ResolvedInstallRoot)
    Set-Content -LiteralPath $ReadmePath -Value $readme -Encoding UTF8

    Write-Step 'Validating local package paths'
    foreach ($packagePath in $packagePaths) {
        $resolvedPath = Resolve-Path -LiteralPath (Join-Path $PiDir $packagePath) -ErrorAction Stop
        Write-Info "OK: $resolvedPath"
    }

    Write-Step 'Done'
    Write-Host 'Standalone installation prepared successfully.' -ForegroundColor Green
    Write-Host "Target folder: $ResolvedInstallRoot"
    Write-Host "Log file: $InstallLogPath"
    Write-Host ''
    Write-Host 'Start with:'
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$StartScriptPath`""
}
catch {
    $ScriptExitCode = 1
    Write-ErrorLine $_.Exception.Message
    if ($ResolvedInstallRoot) {
        Write-Host "Target folder: $ResolvedInstallRoot" -ForegroundColor Yellow
    }
}
finally {
    if ($TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}

exit $ScriptExitCode
