param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PiArgs
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
try {
    $null = & chcp.com 65001
}
catch {
}
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ShimDir = Join-Path $ProjectRoot '.pi\bin'
if (Test-Path -LiteralPath $ShimDir) {
    $env:Path = $ShimDir + ';' + $env:Path
}
Set-Location $ProjectRoot

$piCmd = Get-Command 'pi' -ErrorAction SilentlyContinue
$piCmdPath = if ($piCmd) { $piCmd.Source } else { $null }
if (-not $piCmdPath) {
    $piFallback = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'npm\pi.cmd'
    if (Test-Path -LiteralPath $piFallback) {
        $piCmdPath = $piFallback
    }
}

if (-not $piCmdPath) {
    throw 'pi was not found. Please run scripts/install-pi-stack.ps1 first.'
}

& $piCmdPath @PiArgs
exit $LASTEXITCODE
