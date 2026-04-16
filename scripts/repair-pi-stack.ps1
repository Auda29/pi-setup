[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [switch]$IncludeTwinCATAds,
    [string]$TwinCATAdsSource,
    [switch]$RequirePython,
    [switch]$UseLatestPackageVersions,
    [switch]$ForceCleanNodeModules
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$InstallerScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ResolvedProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path
$PackagesDir = Join-Path $ResolvedProjectRoot '.pi-packages'
$PiDir = Join-Path $ResolvedProjectRoot '.pi'
$LogsDir = Join-Path $PiDir 'logs'
$RepairLogPath = Join-Path $LogsDir ("repair-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$TranscriptStarted = $false
$ScriptExitCode = 0

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

function Get-CommandPathSafe {
    param([Parameter(Mandatory = $true)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
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
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Get-PythonCommandSpec {
    param([Parameter(Mandatory = $true)][string]$PythonPath)

    $leaf = Split-Path -Leaf $PythonPath
    $baseArguments = @()
    if ($leaf -ieq 'py.exe' -or $leaf -ieq 'py') {
        $baseArguments += '-3'
    }

    return [ordered]@{
        FilePath      = $PythonPath
        BaseArguments = $baseArguments
    }
}

function Invoke-PythonCommand {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $pythonSpec = Get-PythonCommandSpec -PythonPath $PythonPath
    $allArguments = @($pythonSpec['BaseArguments']) + @($Arguments)
    Invoke-External -FilePath $pythonSpec['FilePath'] -Arguments $allArguments -WorkingDirectory $WorkingDirectory
}

function Test-MemPalacePythonBackend {
    $pythonPath = Get-CommandPathSafe -Name 'py'
    if (-not $pythonPath) {
        $pythonPath = Get-CommandPathSafe -Name 'python'
    }

    if (-not $pythonPath) {
        throw 'MemPalace backend check failed: neither py nor python is available.'
    }

    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'

    Write-Step 'Validating MemPalace backend after repair'
    Invoke-PythonCommand -PythonPath $pythonPath -Arguments @('-c', 'import mempalace; import mempalace.mcp_server; print("mempalace backend ok")')
}

Ensure-Directory -Path $PiDir
Ensure-Directory -Path $LogsDir

try {
    try {
        Start-Transcript -Path $RepairLogPath -Force | Out-Null
        $TranscriptStarted = $true
    }
    catch {
        Write-Warning "Could not start transcript: $($_.Exception.Message)"
    }

    Write-Info "Project root: $ResolvedProjectRoot"
    Write-Info "Repair log: $RepairLogPath"

    if ($ForceCleanNodeModules) {
        Write-Step 'Cleaning broken local npm artifacts'
        $nodeModulesPath = Join-Path $PackagesDir 'node_modules'
        $packageLockPath = Join-Path $PackagesDir 'package-lock.json'
        if (Test-Path -LiteralPath $nodeModulesPath) {
            Remove-Item -LiteralPath $nodeModulesPath -Recurse -Force
            Write-Info "Removed: $nodeModulesPath"
        }
        if (Test-Path -LiteralPath $packageLockPath) {
            Remove-Item -LiteralPath $packageLockPath -Force
            Write-Info "Removed: $packageLockPath"
        }
    }

    Write-Step 'Re-running installer in repair mode'
    $installScript = Join-Path $InstallerScriptDir 'install-pi-stack.ps1'
    if (-not (Test-Path -LiteralPath $installScript)) {
        throw "Install script is missing: $installScript"
    }

    $arguments = @('-ExecutionPolicy', 'Bypass', '-File', $installScript, '-ProjectRoot', $ResolvedProjectRoot)
    if ($IncludeTwinCATAds) {
        $arguments += '-IncludeTwinCATAds'
        if ([string]::IsNullOrWhiteSpace($TwinCATAdsSource)) {
            throw 'If -IncludeTwinCATAds is set, -TwinCATAdsSource must also be provided.'
        }
        $arguments += @('-TwinCATAdsSource', $TwinCATAdsSource)
    }
    if ($RequirePython) { $arguments += '-RequirePython' }
    if ($UseLatestPackageVersions) { $arguments += '-UseLatestPackageVersions' }

    Invoke-WithRetry -Description 'Re-running install script' -Action {
        Invoke-External -FilePath 'powershell.exe' -Arguments $arguments -WorkingDirectory $ResolvedProjectRoot
    } -MaxAttempts 2 -DelaySeconds 5

    Test-MemPalacePythonBackend

    Write-Step 'Done'
    Write-Host 'Repair completed successfully.' -ForegroundColor Green
    Write-Host "Log file: $RepairLogPath"
}
catch {
    $ScriptExitCode = 1
    Write-ErrorLine $_.Exception.Message
    Write-Host "Log file: $RepairLogPath" -ForegroundColor Yellow
}
finally {
    if ($TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}

exit $ScriptExitCode
