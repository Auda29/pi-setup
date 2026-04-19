[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [switch]$RemoveGlobalPi,
    [switch]$KeepSettings,
    [switch]$KeepLogs,
    [switch]$KeepBackups
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ResolvedProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path
$ProjectScriptsDir = Join-Path $ResolvedProjectRoot 'scripts'
$PiDir = Join-Path $ResolvedProjectRoot '.pi'
$ShimDir = Join-Path $PiDir 'bin'
$SettingsPath = Join-Path $PiDir 'settings.json'
$StartScriptPath = Join-Path $ProjectScriptsDir 'start-pi.ps1'
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

function Get-PiExecutable {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    $piCmd = Join-Path $appData 'npm\pi.cmd'
    if (Test-Path -LiteralPath $piCmd) {
        return $piCmd
    }

    $piCmdResolved = Get-CommandPathSafe -Name 'pi.cmd'
    if ($piCmdResolved) { return $piCmdResolved }

    $pi = Get-CommandPathSafe -Name 'pi'
    if ($pi) { return $pi }

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

function Remove-PathSafe {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Info "Skipped, not present: $Path"
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Remove')) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        Write-Info "Removed: $Path"
    }
}

function Get-PiPackageSources {
    return @(
        'npm:mempalace-pi',
        'npm:pi-lens',
        'npm:pi-mcp-adapter',
        'npm:pi-subagents',
        'npm:pi-web-access',
        'npm:pi-twincat-ads'
    )
}

function Remove-PiPackageSafe {
    param(
        [Parameter(Mandatory = $true)][string]$PiExecutablePath,
        [Parameter(Mandatory = $true)][string]$Source,
        [switch]$Local
    )

    $args = @('uninstall', $Source)
    if ($Local) {
        $args += '--local'
    }

    try {
        Invoke-External -FilePath $PiExecutablePath -Arguments $args -WorkingDirectory $ResolvedProjectRoot
    }
    catch {
        Write-Warning "Could not remove Pi package '$Source': $($_.Exception.Message)"
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
        Write-Warning "Could not start transcript: $($_.Exception.Message)"
    }

    Write-Info "Project root: $ResolvedProjectRoot"
    Write-Info "Uninstall log: $UninstallLogPath"

    if (-not $KeepSettings) {
        $piExe = Get-PiExecutable
        if ($piExe) {
            Write-Step 'Removing local Pi packages'
            foreach ($source in Get-PiPackageSources) {
                Remove-PiPackageSafe -PiExecutablePath $piExe -Source $source -Local
            }
        }
        else {
            Write-Warning 'pi was not found. Local Pi packages could not be removed from project settings automatically.'
        }
    }
    else {
        Write-Info 'Keeping .pi/settings.json, so local Pi package entries are left untouched.'
    }

    Write-Step 'Removing legacy local package directory'
    Remove-PathSafe -Path (Join-Path $ResolvedProjectRoot '.pi-packages')

    Write-Step 'Removing project-local Pi files'
    Remove-PathSafe -Path $ShimDir

    if (-not $KeepSettings) {
        Remove-PathSafe -Path $SettingsPath
    } else {
        Write-Info 'Keeping .pi/settings.json'
    }

    Remove-PathSafe -Path $StartScriptPath

    if (-not $KeepBackups) {
        Remove-PathSafe -Path $BackupsDir
    } else {
        Write-Info 'Keeping .pi/backups/'
    }

    if (-not $KeepLogs) {
        $keepCurrentLog = $UninstallLogPath
        if (Test-Path -LiteralPath $LogsDir) {
            Get-ChildItem -LiteralPath $LogsDir -File | Where-Object { $_.FullName -ne $keepCurrentLog } | ForEach-Object {
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                    Write-Info "Removed: $($_.FullName)"
                }
            }
        }
    } else {
        Write-Info 'Keeping .pi/logs/'
    }

    if ($RemoveGlobalPi) {
        Write-Step 'Removing global pi'
        $npmExe = Get-NpmExecutable
        if (-not $npmExe) {
            throw 'npm was not found. Global pi cannot be removed automatically.'
        }

        if ($PSCmdlet.ShouldProcess('@mariozechner/pi-coding-agent', 'npm uninstall -g')) {
            Invoke-External -FilePath $npmExe -Arguments @('uninstall', '-g', '@mariozechner/pi-coding-agent', '--no-fund', '--no-audit')
        }
    } else {
        Write-Info 'Global pi remains installed. Use -RemoveGlobalPi to remove it.'
    }

    Write-Step 'Cleaning empty directories'
    if ((Test-Path -LiteralPath $PiDir) -and -not (Get-ChildItem -LiteralPath $PiDir -Force | Select-Object -First 1)) {
        Remove-PathSafe -Path $PiDir
    }

    Write-Step 'Done'
    Write-Host 'Pi stack has been removed.' -ForegroundColor Green
    Write-Host "Log file: $UninstallLogPath"
}
catch {
    $ScriptExitCode = 1
    Write-ErrorLine $_.Exception.Message
    Write-Host "Log file: $UninstallLogPath" -ForegroundColor Yellow
}
finally {
    if ($TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}

exit $ScriptExitCode
