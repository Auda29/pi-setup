[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$RemoveGlobalPi,
    [switch]$KeepSettings,
    [switch]$KeepLogs,
    [switch]$KeepBackups
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$PiDir = Join-Path $ProjectRoot '.pi'
$PackagesDir = Join-Path $ProjectRoot '.pi-packages'
$SettingsPath = Join-Path $PiDir 'settings.json'
$StartScriptPath = Join-Path $ScriptDir 'start-pi.ps1'
$LogsDir = Join-Path $PiDir 'logs'
$BackupsDir = Join-Path $PiDir 'backups'
$UninstallLogPath = Join-Path $LogsDir ("uninstall-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
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

function Get-NpmExecutable {
    $npmCmd = Get-CommandPathSafe -Name 'npm.cmd'
    if ($npmCmd) { return $npmCmd }
    $npm = Get-CommandPathSafe -Name 'npm'
    if ($npm) { return $npm }
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

function Remove-PathSafe {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Info "Uebersprungen, nicht vorhanden: $Path"
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Remove')) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        Write-Info "Entfernt: $Path"
    }
}

Ensure-Directory -Path $PiDir
Ensure-Directory -Path $LogsDir

try {
    try {
        Start-Transcript -Path $UninstallLogPath -Force | Out-Null
        $TranscriptStarted = $true
    }
    catch {
        Write-Warning "Konnte kein Transcript starten: $($_.Exception.Message)"
    }

    Write-Info "Uninstall-Log: $UninstallLogPath"

    Write-Step 'Entferne lokale Pi-Packages'
    Remove-PathSafe -Path $PackagesDir

    Write-Step 'Entferne projektlokale Pi-Dateien'
    if (-not $KeepSettings) {
        Remove-PathSafe -Path $SettingsPath
    } else {
        Write-Info 'Behalte .pi/settings.json'
    }

    Remove-PathSafe -Path $StartScriptPath

    if (-not $KeepBackups) {
        Remove-PathSafe -Path $BackupsDir
    } else {
        Write-Info 'Behalte .pi/backups/'
    }

    if (-not $KeepLogs) {
        $keepCurrentLog = $UninstallLogPath
        if (Test-Path -LiteralPath $LogsDir) {
            Get-ChildItem -LiteralPath $LogsDir -File | Where-Object { $_.FullName -ne $keepCurrentLog } | ForEach-Object {
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                    Write-Info "Entfernt: $($_.FullName)"
                }
            }
        }
    } else {
        Write-Info 'Behalte .pi/logs/'
    }

    if ($RemoveGlobalPi) {
        Write-Step 'Entferne globales pi'
        $npmExe = Get-NpmExecutable
        if (-not $npmExe) {
            throw 'npm wurde nicht gefunden. Globales pi kann nicht automatisch entfernt werden.'
        }

        if ($PSCmdlet.ShouldProcess('@mariozechner/pi-coding-agent', 'npm uninstall -g')) {
            Invoke-External -FilePath $npmExe -Arguments @('uninstall', '-g', '@mariozechner/pi-coding-agent', '--no-fund', '--no-audit')
        }
    } else {
        Write-Info 'Globales pi bleibt installiert. Nutze -RemoveGlobalPi zum Entfernen.'
    }

    Write-Step 'Bereinige leere Verzeichnisse'
    if ((Test-Path -LiteralPath $PiDir) -and -not (Get-ChildItem -LiteralPath $PiDir -Force | Select-Object -First 1)) {
        Remove-PathSafe -Path $PiDir
    }

    Write-Step 'Fertig'
    Write-Host 'Pi-Stack wurde entfernt.' -ForegroundColor Green
    Write-Host "Logdatei: $UninstallLogPath"
}
catch {
    $ScriptExitCode = 1
    Write-ErrorLine $_.Exception.Message
    Write-Host "Logdatei: $UninstallLogPath" -ForegroundColor Yellow
}
finally {
    if ($TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}

exit $ScriptExitCode
