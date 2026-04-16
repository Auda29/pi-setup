[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.pi-stack'),
    [switch]$RemoveGlobalPi,
    [switch]$KeepInstallRoot,
    [switch]$KeepGlobalSettings,
    [switch]$KeepGlobalAgents
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptExitCode = 0
$TranscriptStarted = $false
$ResolvedInstallRoot = $null
$UserProfilePath = [Environment]::GetFolderPath('UserProfile')
$GlobalPiAgentDir = Join-Path $UserProfilePath '.pi\agent'
$GlobalPiAgentSettingsPath = Join-Path $GlobalPiAgentDir 'settings.json'
$GlobalAgentsDir = Join-Path $UserProfilePath '.pi\agents'
$GlobalAgentsPath = Join-Path $GlobalAgentsDir 'AGENTS.md'
$GlobalUninstallLogDir = Join-Path $UserProfilePath '.pi\logs'
$GlobalUninstallLogPath = Join-Path $GlobalUninstallLogDir ('global-uninstall-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

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
            throw "Command failed ($exitCode): $FilePath $($Arguments -join ' ')"
        }
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
    }
}

function ConvertTo-HashtableCompatible {
    param($InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-HashtableCompatible -InputObject $InputObject[$key]
        }
        return $result
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and ($InputObject -isnot [string])) {
        $result = @()
        foreach ($item in $InputObject) {
            $result += ,(ConvertTo-HashtableCompatible -InputObject $item)
        }
        return $result
    }

    if (($InputObject -is [psobject]) -and $InputObject.PSObject.Properties.Count -gt 0) {
        $result = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            if ($property.MemberType -like '*Property') {
                $result[$property.Name] = ConvertTo-HashtableCompatible -InputObject $property.Value
            }
        }
        return $result
    }

    return $InputObject
}

function Load-JsonObject {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{}
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{}
    }

    $convertFromJsonCommand = Get-Command ConvertFrom-Json -ErrorAction Stop
    if ($convertFromJsonCommand.Parameters.ContainsKey('AsHashtable')) {
        return ($raw | ConvertFrom-Json -AsHashtable)
    }

    return (ConvertTo-HashtableCompatible -InputObject ($raw | ConvertFrom-Json))
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

function Remove-GeneratedAgentsSection {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Info "Skipped, not present: $Path"
        return
    }

    $beginMarker = '<!-- BEGIN PI-SETUP-AUTOGENERATED -->'
    $endMarker = '<!-- END PI-SETUP-AUTOGENERATED -->'
    $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $pattern = [regex]::Escape($beginMarker) + '[\s\S]*?' + [regex]::Escape($endMarker) + '\r?\n?'
    $updated = [regex]::Replace($existing, $pattern, '')

    if ([string]::IsNullOrWhiteSpace($updated)) {
        Remove-PathSafe -Path $Path
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Update autogenerated AGENTS.md section')) {
        Set-Content -LiteralPath $Path -Value ($updated.TrimEnd() + "`r`n") -Encoding UTF8
        Write-Info "Updated: $Path"
    }
}

Ensure-Directory -Path $GlobalUninstallLogDir

try {
    try {
        Start-Transcript -Path $GlobalUninstallLogPath -Force | Out-Null
        $TranscriptStarted = $true
    }
    catch {
        Write-Warning "Could not start transcript: $($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $InstallRoot) {
        $ResolvedInstallRoot = (Resolve-Path -LiteralPath $InstallRoot).Path
    } else {
        $ResolvedInstallRoot = $InstallRoot
    }

    Write-Info "Install root: $ResolvedInstallRoot"
    Write-Info "Global settings: $GlobalPiAgentSettingsPath"
    Write-Info "Global AGENTS.md: $GlobalAgentsPath"
    Write-Info "Log file: $GlobalUninstallLogPath"

    $packagesDir = Join-Path $ResolvedInstallRoot '.pi-packages'
    $globalPackagePaths = @(
        (Join-Path $packagesDir 'node_modules\pi-subagents'),
        (Join-Path $packagesDir 'node_modules\pi-mcp-adapter'),
        (Join-Path $packagesDir 'node_modules\pi-lens'),
        (Join-Path $packagesDir 'node_modules\pi-web-access'),
        (Join-Path $packagesDir 'node_modules\mempalace-pi'),
        (Join-Path $packagesDir 'node_modules\pi-twincat-ads')
    )

    if (-not $KeepGlobalSettings -and (Test-Path -LiteralPath $GlobalPiAgentSettingsPath)) {
        Write-Step 'Cleaning global Pi settings'
        $settings = Load-JsonObject -Path $GlobalPiAgentSettingsPath
        $existingPackages = @($settings['packages'])
        $remainingPackages = @()
        foreach ($pkg in $existingPackages) {
            if ($pkg -isnot [string]) { continue }
            if ($globalPackagePaths -contains $pkg) { continue }
            $remainingPackages += $pkg
        }
        $settings['packages'] = $remainingPackages
        Save-JsonObject -Path $GlobalPiAgentSettingsPath -Data $settings
        Write-Info 'Removed global package references from global Pi settings.'
    }
    elseif ($KeepGlobalSettings) {
        Write-Info 'Keeping global Pi settings.'
    }

    if (-not $KeepGlobalAgents) {
        Write-Step 'Cleaning global AGENTS.md'
        Remove-GeneratedAgentsSection -Path $GlobalAgentsPath
    }
    else {
        Write-Info 'Keeping global AGENTS.md.'
    }

    if (-not $KeepInstallRoot) {
        Write-Step 'Removing global install root'
        Remove-PathSafe -Path $ResolvedInstallRoot
    }
    else {
        Write-Info 'Keeping install root.'
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
    }
    else {
        Write-Info 'Global pi remains installed. Use -RemoveGlobalPi to remove it.'
    }

    Write-Step 'Done'
    Write-Host 'Global Pi stack has been removed or cleaned up.' -ForegroundColor Green
    Write-Host "Log file: $GlobalUninstallLogPath"
}
catch {
    $ScriptExitCode = 1
    Write-ErrorLine $_.Exception.Message
    Write-Host "Log file: $GlobalUninstallLogPath" -ForegroundColor Yellow
}
finally {
    if ($TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}

exit $ScriptExitCode
