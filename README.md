# Pi Setup Stack

Robustes Windows-Setup fuer deinen Pi-Stack mit diesen Komponenten:

- `@mariozechner/pi-coding-agent`
- `pi-subagents`
- `pi-mcp-adapter`
- `pi-lens`
- `pi-web-access`
- `mempalace-pi`
- optional spaeter `pi-twincat-ads`

Ziel: Ein Setup, das sowohl auf **frischen Windows-Systemen** als auch auf Rechnern mit **bereits vorhandenem Pi** moeglichst reproduzierbar durchlaeuft.

## Was das Setup macht

`scripts/install-pi-stack.ps1` erledigt folgendes:

1. prueft, ob es auf Windows laeuft
2. installiert fehlende Voraussetzungen wenn moeglich per `winget`
   - Node.js LTS
   - Git for Windows
   - optional Python 3
3. installiert oder aktualisiert `@mariozechner/pi-coding-agent` global
4. installiert die Pi-Erweiterungen lokal in `.pi-packages`
5. schreibt eine robuste `.pi/settings.json`
   - `npmCommand`
   - `shellPath`
   - `packages`
   - `sessionDir`
6. legt Backups bestehender Settings an
7. erzeugt ein Startskript fuer Windows: `scripts/start-pi.ps1`
8. schreibt ein Install-Log nach `.pi/logs/`

## Warum dieser Ansatz?

Unter Windows ist der direkte Weg ueber `pi install npm:...` nicht immer der nervenschonendste Weg. Deshalb installiert dieses Setup die Erweiterungen **lokal per npm** und bindet sie **ueber lokale Paketpfade** in `.pi/settings.json` ein.

Das ist fuer dein Ziel stabiler, reproduzierbarer und leichter zu debuggen.

## Voraussetzungen

Empfohlen:

- Windows 11 oder aktuelles Windows 10
- PowerShell 5.1+ oder PowerShell 7+
- `winget` verfuegbar
- Internetzugang fuer `winget` und `npm`

Falls `winget` fehlt, musst du fehlende Voraussetzungen manuell installieren.

## Schnellstart

Im Projektordner:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1
```

Danach Pi starten mit:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-pi.ps1
```

## Empfohlener Start unter Windows

Nutze zum Starten von Pi moeglichst dieses Skript:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-pi.ps1
```

Das setzt fuer die Session:

- `PYTHONUTF8=1`
- `PYTHONIOENCODING=utf-8`

Das hilft besonders bei `mempalace-pi` unter Windows.

## Optionen des Install-Skripts

### Standardinstallation

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1
```

### Python zwingend verlangen

Wenn `mempalace-pi` direkt sauber mit vorbereitet werden soll:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1 -RequirePython
```

### Neueste statt gepinnter Paketversionen verwenden

Standardmaessig verwendet das Repo gepinnte Versionen fuer mehr Reproduzierbarkeit.

Falls du bewusst auf `latest` gehen willst:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1 -UseLatestPackageVersions
```

### Lokales `pi-twincat-ads` mit installieren

Sobald dein Paket lokal vorliegt:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1 `
  -IncludeTwinCATAds `
  -TwinCATAdsSource ..\pi-twincat-ads
```

## Exit-Codes

Das Install-Skript liefert absichtlich einfache Exit-Codes:

- `0` = erfolgreich
- `1` = Fehler waehrend Installation oder Validierung

Beispiel fuer CI oder Wrapper-Skripte:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-pi-stack.ps1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installation fehlgeschlagen"
}
```

## Logging

Jeder Lauf schreibt ein Log nach:

```text
.pi/logs/install-YYYYMMDD-HHMMSS.log
```

Wenn etwas schiefgeht, zuerst dort reinschauen.

## Retry-Strategie

Das Skript verwendet Retries fuer die typischen Wackelkandidaten:

- `winget install`
- `npm install -g @mariozechner/pi-coding-agent`
- `npm install` in `.pi-packages`
- optional `npm install` fuer `pi-twincat-ads`

Damit ueberlebt es eher:

- kurze Netzwerkprobleme
- Registry-Zickereien
- temporaere npm- oder winget-Aussetzer

## Wichtige Dateien

- `scripts/install-pi-stack.ps1` - Bootstrap/Installer
- `scripts/start-pi.ps1` - empfohlener Start unter Windows
- `.pi-packages/package.json` - lokale Stack-Definition
- `.pi/settings.json` - projektlokale Pi-Konfiguration
- `.pi/backups/` - Backups vorhandener Settings
- `.pi/logs/` - Install-Logs

## Installierte Pakete

Standardmaessig gepinnt:

- `pi-subagents` `0.14.1`
- `pi-mcp-adapter` `2.4.0`
- `pi-lens` `3.8.26`
- `pi-web-access` `0.10.6`
- `mempalace-pi` `0.2.0`

## Was passiert bei bestehender Pi-Installation?

Genau dafuer ist das Skript gebaut:

- vorhandenes `pi` wird nicht blind vorausgesetzt, sondern aktualisiert
- vorhandene `.pi/settings.json` wird vor dem Ueberschreiben gesichert
- vorhandene `.pi-packages/package.json` wird ergaenzt statt stumpf zerstoert
- Paketpfade werden dedupliziert

## Typische Probleme

### 1. `winget` fehlt

Dann musst du Node.js, Git for Windows und optional Python manuell installieren.

### 2. `pi` wird nach globalem npm-Install nicht gefunden

Pruefe typischerweise:

- `%APPDATA%\npm` im PATH
- ob `pi.cmd` unter `%APPDATA%\npm` existiert

Das Startskript hat dafuer bereits einen Fallback auf `%APPDATA%\npm\pi.cmd`.

### 3. Git Bash fehlt

Pi braucht unter Windows eine Bash-Shell. Das Skript versucht deshalb Git for Windows zu installieren und setzt danach `shellPath` in `.pi/settings.json`.

### 4. Python-/Encoding-Probleme mit `mempalace-pi`

Nutze zum Starten von Pi immer:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-pi.ps1
```

## NPM-/Pi-Mechanik

Dieses Repo nutzt **lokale Paketpfade** in `.pi/settings.json`, also z. B.:

```json
{
  "packages": [
    "../.pi-packages/node_modules/pi-subagents"
  ]
}
```

Dadurch ist der Stack projektlokal versionierbar und nachvollziehbar.

## Repair und Uninstall

### Repair

Wenn ein Setup halb kaputt ist, Abhaengigkeiten fehlen oder lokale npm-Artefakte beschaedigt sind:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\repair-pi-stack.ps1
```

Mit hartem Reset der lokalen npm-Artefakte:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\repair-pi-stack.ps1 -ForceCleanNodeModules
```

Mit lokalem `pi-twincat-ads`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\repair-pi-stack.ps1 `
  -IncludeTwinCATAds `
  -TwinCATAdsSource ..\pi-twincat-ads
```

### Uninstall

Projektlokalen Pi-Stack entfernen:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-pi-stack.ps1
```

Auch globales Pi entfernen:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-pi-stack.ps1 -RemoveGlobalPi
```

Settings, Logs oder Backups behalten:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-pi-stack.ps1 -KeepSettings -KeepLogs -KeepBackups
```

Beide Skripte schreiben Logs nach `.pi/logs/`.

## Naechste sinnvolle Schritte

Wenn du willst, kannst du als Naechstes noch ergaenzen:

- ein Meta-Paket fuer deinen kompletten Stack
- eine CI-Pruefung fuer das Setup
- automatische Checks fuer `pi-twincat-ads`
