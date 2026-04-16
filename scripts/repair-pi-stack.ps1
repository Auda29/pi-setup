[CmdletBinding()]
param(
    [switch]$IncludeTwinCATAds,
    [string]$TwinCATAdsSource,
    [switch]$RequirePython,
    [switch]$UseLatestPackageVersions,
    [switch]$ForceCleanNodeModules
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$PackagesDir = Join-Path $ProjectRoot '.pi-packages'
$PiDir = Join-Path $ProjectRoot '.pi'
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
            throw "Befehl fehlgeschlagen ($exitCode): $FilePath $($Arguments -join ' ')"
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
            Write-Info "$Description (Versuch $attempt/$MaxAttempts)"
            & $Action
            return
        }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warning "$Description fehlgeschlagen: $($_.Exception.Message)"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

Ensure-Directory -Path $PiDir
Ensure-Directory -Path $LogsDir

try {
    try {
        Start-Transcript -Path $RepairLogPath -Force | Out-Null
        $TranscriptStarted = $true
    }
    catch {
        Write-Warning "Konnte kein Transcript starten: $($_.Exception.Message)"
    }

    Write-Info "Repair-Log: $RepairLogPath"

    if ($ForceCleanNodeModules) {
        Write-Step 'Bereinige defekte lokale npm-Artefakte'
        $nodeModulesPath = Join-Path $PackagesDir 'node_modules'
        $packageLockPath = Join-Path $PackagesDir 'package-lock.json'
        if (Test-Path -LiteralPath $nodeModulesPath) {
            Remove-Item -LiteralPath $nodeModulesPath -Recurse -Force
            Write-Info "Entfernt: $nodeModulesPath"
        }
        if (Test-Path -LiteralPath $packageLockPath) {
            Remove-Item -LiteralPath $packageLockPath -Force
            Write-Info "Entfernt: $packageLockPath"
        }
    }

    Write-Step 'Fuehre Installer im Repair-Modus erneut aus'
    $installScript = Join-Path $ScriptDir 'install-pi-stack.ps1'
    if (-not (Test-Path -LiteralPath $installScript)) {
        throw "Install-Script fehlt: $installScript"
    }

    $arguments = @('-ExecutionPolicy', 'Bypass', '-File', $installScript)
    if ($IncludeTwinCATAds) {
        $arguments += '-IncludeTwinCATAds'
        if ([string]::IsNullOrWhiteSpace($TwinCATAdsSource)) {
            throw 'Wenn -IncludeTwinCATAds gesetzt ist, muss auch -TwinCATAdsSource angegeben werden.'
        }
        $arguments += @('-TwinCATAdsSource', $TwinCATAdsSource)
    }
    if ($RequirePython) { $arguments += '-RequirePython' }
    if ($UseLatestPackageVersions) { $arguments += '-UseLatestPackageVersions' }

    Invoke-WithRetry -Description 'Install-Script erneut ausfuehren' -Action {
        Invoke-External -FilePath 'powershell.exe' -Arguments $arguments -WorkingDirectory $ProjectRoot
    } -MaxAttempts 2 -DelaySeconds 5

    Write-Step 'Fertig'
    Write-Host 'Repair erfolgreich abgeschlossen.' -ForegroundColor Green
    Write-Host "Logdatei: $RepairLogPath"
}
catch {
    $ScriptExitCode = 1
    Write-ErrorLine $_.Exception.Message
    Write-Host "Logdatei: $RepairLogPath" -ForegroundColor Yellow
}
finally {
    if ($TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}

exit $ScriptExitCode
