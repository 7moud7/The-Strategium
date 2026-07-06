# ── The Strategium — PC updater ─────────────────────────────────────────────
# Downloads the latest app into your OneDrive Warhammer folder so the newest
# build is always one double-click away (and synced by OneDrive to all your
# devices). Run it any time an update is pushed to GitHub:
#
#   Right-click → "Run with PowerShell"
#   or:  powershell -ExecutionPolicy Bypass -File .\Update-Strategium.ps1
#
# Optional: schedule it daily via Task Scheduler for automatic updates.

param(
  # Where to install. Defaults to your OneDrive Warhammer folder.
  [string]$Dest = "$env:USERPROFILE\OneDrive\Warhammer\TheStrategium",
  # Branch to pull from. Switch to "main" once the app branch is merged.
  [string]$Branch = "claude/wh40k-rules-comprehension-3mcajp"
)

$repo = "https://raw.githubusercontent.com/7moud7/The-Strategium/$Branch"

New-Item -ItemType Directory -Force -Path $Dest | Out-Null

Write-Host "Downloading The Strategium ($Branch)..." -ForegroundColor Yellow
Invoke-WebRequest -Uri "$repo/App/thestrategium.html" -OutFile "$Dest\TheStrategium.html"

Write-Host ""
Write-Host "Installed:  $Dest\TheStrategium.html" -ForegroundColor Green
Write-Host "Open that file in your browser (Chrome/Edge) to play."
Write-Host "Your collection/armies are saved in the browser, not the file -"
Write-Host "updating never touches your data. Use Settings -> Export Backup anyway."
