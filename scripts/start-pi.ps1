param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PiArgs
)

$ErrorActionPreference = 'Stop'
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
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
    throw 'pi wurde nicht gefunden. Bitte zuerst scripts/install-pi-stack.ps1 ausfuehren.'
}

& $piCmdPath @PiArgs
exit $LASTEXITCODE
