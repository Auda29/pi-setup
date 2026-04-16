[CmdletBinding()]
param(
    [switch]$IncludeTwinCATAds,
    [string]$TwinCATAdsSource,
    [switch]$RequirePython,
    [switch]$UseLatestPackageVersions
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$PiDir = Join-Path $ProjectRoot '.pi'
$PackagesDir = Join-Path $ProjectRoot '.pi-packages'
$PackagesManifestPath = Join-Path $PackagesDir 'package.json'
$PackagesLockPath = Join-Path $PackagesDir 'package-lock.json'
$SettingsPath = Join-Path $PiDir 'settings.json'
$StartScriptPath = Join-Path $ScriptDir 'start-pi.ps1'
$SettingsBackupDir = Join-Path $PiDir 'backups'
$LogsDir = Join-Path $PiDir 'logs'
$InstallLogPath = Join-Path $LogsDir ("install-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$TranscriptStarted = $false
$ScriptExitCode = 0

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

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $combined = @($machinePath, $userPath) -join ';'
    if (-not [string]::IsNullOrWhiteSpace($combined)) {
        $env:Path = $combined
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Test-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-CommandPathSafe {
    param([Parameter(Mandatory = $true)][string]$Name)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    return $null
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory
    )

    if ($WorkingDirectory) {
        Push-Location $WorkingDirectory
    }

    try {
        Write-Info ("Run: " + $FilePath + ' ' + ($Arguments -join ' '))
        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "Command failed ($exitCode): $FilePath $($Arguments -join ' ')"
        }
    }
    finally {
        if ($WorkingDirectory) {
            Pop-Location
        }
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
            if ($attempt -ge $MaxAttempts) {
                throw
            }
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

function Load-JsonObject {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{}
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    $obj = $raw | ConvertFrom-Json -AsHashtable
    if ($null -eq $obj) {
        return @{}
    }

    return $obj
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

function Backup-IfExists {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Ensure-Directory -Path $SettingsBackupDir
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $target = Join-Path $SettingsBackupDir ((Split-Path -Leaf $Path) + '.' + $timestamp + '.bak')
    Copy-Item -LiteralPath $Path -Destination $target -Force
    Write-Info "Backup created: $target"
}

function Merge-UniqueStrings {
    param(
        [object[]]$Existing,
        [object[]]$Incoming
    )

    $list = New-Object System.Collections.Generic.List[string]
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in @($Existing) + @($Incoming)) {
        if ($null -eq $item) { continue }
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($seen.Add($text)) {
            $list.Add($text)
        }
    }

    return @($list)
}

function Get-DependencyMap {
    $dependencies = [ordered]@{}
    foreach ($name in $PackageNames) {
        if ($UseLatestPackageVersions) {
            $dependencies[$name] = 'latest'
        }
        else {
            $dependencies[$name] = $PinnedVersions[$name]
        }
    }
    return $dependencies
}

function Ensure-PackageManifest {
    $manifest = [ordered]@{
        name        = 'pi-setup-stack'
        private     = $true
        description = 'Local Pi stack for this project'
        dependencies = (Get-DependencyMap)
    }

    if (-not (Test-Path -LiteralPath $PackagesManifestPath)) {
        Write-Info "Creating $PackagesManifestPath"
        Save-JsonObject -Path $PackagesManifestPath -Data $manifest
        return
    }

    $existing = Load-JsonObject -Path $PackagesManifestPath
    if (-not $existing.ContainsKey('name')) { $existing['name'] = $manifest['name'] }
    $existing['private'] = $true
    if (-not $existing.ContainsKey('description')) { $existing['description'] = $manifest['description'] }

    $deps = [ordered]@{}
    if ($existing.ContainsKey('dependencies') -and $existing['dependencies']) {
        foreach ($entry in $existing['dependencies'].GetEnumerator()) {
            $deps[$entry.Key] = $entry.Value
        }
    }

    foreach ($entry in (Get-DependencyMap).GetEnumerator()) {
        $deps[$entry.Key] = $entry.Value
    }

    $existing['dependencies'] = $deps
    Save-JsonObject -Path $PackagesManifestPath -Data $existing
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

function Test-PackageInstalled {
    param([Parameter(Mandatory = $true)][string]$PackageName)

    $packagePath = Join-Path $PackagesDir ("node_modules\\$PackageName")
    return (Test-Path -LiteralPath $packagePath)
}

function Assert-PackageInstalled {
    param([Parameter(Mandatory = $true)][string]$PackageName)

    if (-not (Test-PackageInstalled -PackageName $PackageName)) {
        throw "Package missing after npm install: $PackageName"
    }
}

Ensure-Directory -Path $PiDir
Ensure-Directory -Path $LogsDir

try {
    try {
        Start-Transcript -Path $InstallLogPath -Force | Out-Null
        $TranscriptStarted = $true
    }
    catch {
        Write-Warning "Could not start transcript: $($_.Exception.Message)"
    }

    Write-Info "Install log: $InstallLogPath"
    Write-Step 'Checking and installing prerequisites'

    if (-not $IsWindows) {
        throw 'This bootstrap script is intended for Windows.'
    }

    $nodePath = Ensure-Command -Name 'node' -WingetPackageId 'OpenJS.NodeJS.LTS' -DisplayName 'Node.js LTS'
    $npmPath = Ensure-Command -Name 'npm' -WingetPackageId 'OpenJS.NodeJS.LTS' -DisplayName 'npm'
    $npmExe = Get-NpmExecutable
    if (-not $npmExe) {
        throw 'Could not resolve npm.'
    }

    Write-Host "node: $(& $nodePath --version)"
    Write-Host "npm:  $(& $npmExe --version)"

    $gitBashPath = Get-GitBashPath
    if (-not $gitBashPath) {
        Ensure-Command -Name 'git' -WingetPackageId 'Git.Git' -DisplayName 'Git for Windows'
        $gitBashPath = Get-GitBashPath
    }

    if ($gitBashPath) {
        Write-Host "bash: $gitBashPath"
    } else {
        throw 'No bash shell found. Pi needs Git Bash or another bash.exe on Windows.'
    }

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
    } else {
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

    Write-Step 'Preparing project structure'
    Ensure-Directory -Path $PackagesDir
    Ensure-PackageManifest

    Write-Step 'Installing local Pi packages via npm'
    Invoke-WithRetry -Description 'npm install for .pi-packages' -Action {
        Invoke-External -FilePath $npmExe -WorkingDirectory $PackagesDir -Arguments @('install', '--no-fund', '--no-audit')
    } -MaxAttempts 3 -DelaySeconds 5

    foreach ($packageName in $PackageNames) {
        Assert-PackageInstalled -PackageName $packageName
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
        Assert-PackageInstalled -PackageName 'pi-twincat-ads'
    }

    Write-Step 'Writing robust Pi project configuration'
    Backup-IfExists -Path $SettingsPath
    $settings = Load-JsonObject -Path $SettingsPath

    $settings['npmCommand'] = @($npmExe)
    $settings['shellPath'] = $gitBashPath
    $settings['sessionDir'] = '.pi/sessions'

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

    $settings['packages'] = Merge-UniqueStrings -Existing $settings['packages'] -Incoming $packagePaths
    Save-JsonObject -Path $SettingsPath -Data $settings

    Write-Step 'Writing start script for mempalace/Python UTF-8'
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
    throw 'pi was not found. Please run scripts/install-pi-stack.ps1 first.'
}

& `$piCmdPath @PiArgs
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $StartScriptPath -Value $startScript -Encoding UTF8

    Write-Step 'Validating local package paths'
    foreach ($packagePath in $packagePaths) {
        $resolvedPath = Resolve-Path -LiteralPath (Join-Path $PiDir $packagePath) -ErrorAction Stop
        Write-Info "OK: $resolvedPath"
    }

    Write-Step 'Done'
    Write-Host 'Successfully prepared:' -ForegroundColor Green
    Write-Host "  - Global: @mariozechner/pi-coding-agent"
    foreach ($packageName in $PackageNames) {
        Write-Host "  - Local:  $packageName"
    }
    if ($IncludeTwinCATAds) {
        Write-Host '  - Local:  pi-twincat-ads'
    }

    Write-Host "`nImportant files:"
    Write-Host "  - $PackagesManifestPath"
    if (Test-Path -LiteralPath $PackagesLockPath) {
        Write-Host "  - $PackagesLockPath"
    }
    Write-Host "  - $SettingsPath"
    Write-Host "  - $StartScriptPath"
    Write-Host "  - $($MyInvocation.MyCommand.Path)"
    Write-Host "  - $InstallLogPath"

    Write-Host "`nRecommended startup on Windows:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\scripts\start-pi.ps1"
}
catch {
    $ScriptExitCode = 1
    Write-ErrorLine $_.Exception.Message
    Write-Host "Log file: $InstallLogPath" -ForegroundColor Yellow
}
finally {
    if ($TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
        }
    }
}

exit $ScriptExitCode
