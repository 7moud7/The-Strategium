# -- Watch-Updates.ps1 --------------------------------------------------------
# Daily watcher for upstream rules updates. Non-destructive by design:
#   - Wahapedia export timestamp changed  -> runs Update-RulesData.ps1
#     (points sync; the rest of the pipeline stays manual on purpose)
#   - BSData/wh40k-10e release changed    -> logged for review
#   - Warhammer Community downloads page  -> new/changed PDF links logged
# State lives in Reference\Data Exports\update-state.json; a human-readable
# log accumulates in Reference\update-log.txt.
#
# Registered as a Windows scheduled task (see bottom of file for the command).

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = Split-Path $PSScriptRoot -Parent
$refDir = Join-Path (Split-Path $repo -Parent) "Reference"
$statePath = Join-Path $refDir "Data Exports\update-state.json"
$logPath = Join-Path $refDir "update-log.txt"
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $msg
  Add-Content -Path $logPath -Value $line
  Write-Host $line
}

$state = @{ wahapedia = ''; bsdata = ''; warcom = '' }
if (Test-Path $statePath) {
  $j = Get-Content $statePath -Raw | ConvertFrom-Json
  foreach ($k in @('wahapedia','bsdata','warcom')) { if ($j.$k) { $state[$k] = $j.$k } }
}
$changed = $false

# -- 1. Wahapedia --
try {
  $live = ((Invoke-WebRequest -Uri 'https://wahapedia.ru/wh40k10ed/Last_update.csv' -UserAgent $UA -UseBasicParsing).Content -split "`n" | Select-Object -Skip 1 -First 1).Trim().TrimEnd('|')
  if ($live -and $live -ne $state.wahapedia) {
    Log "Wahapedia export changed: '$($state.wahapedia)' -> '$live'. Running points sync..."
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Update-RulesData.ps1') *>&1 |
      ForEach-Object { Add-Content -Path $logPath -Value "    $_" }
    Log "Points sync complete. Review, then push + re-run Build-Obsidian + Supabase ingest (see TSKB 90)."
    $state.wahapedia = $live; $changed = $true
  }
} catch { Log "Wahapedia check failed: $($_.Exception.Message)" }

# -- 2. BSData wh40k-10e releases --
try {
  $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/BSData/wh40k-10e/releases/latest' -UserAgent $UA
  if ($rel.tag_name -and $rel.tag_name -ne $state.bsdata) {
    Log "BSData wh40k-10e new release: $($rel.tag_name) — '$($rel.name)' ($($rel.published_at)). https://github.com/BSData/wh40k-10e/releases"
    $state.bsdata = $rel.tag_name; $changed = $true
  }
} catch { Log "BSData check failed: $($_.Exception.Message)" }

# -- 3. Warhammer Community downloads (balance dataslate / errata PDFs) --
# The public downloads page is JS-rendered; its search API answers directly.
try {
  $body = '{"index":"downloads","searchTerm":"","gameSystem":"warhammer-40000","language":"british-english"}'
  $resp = Invoke-RestMethod -Uri 'https://www.warhammer-community.com/api/search/downloads/' -Method Post -UserAgent $UA -ContentType 'application/json' -Body $body
  $items = @($resp.hits | ForEach-Object { "$($_.title)|$($_.id.last_updated)" }) | Sort-Object
  $sig = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(($items -join "`n")))).Replace('-','').Substring(0,16)
  if ($sig -ne $state.warcom) {
    if ($state.warcom) {
      Log "Warhammer Community downloads changed ($($items.Count) documents) - likely a new dataslate/errata. Recently updated:"
      $resp.hits | Sort-Object { $_.date } -Descending | Select-Object -First 8 |
        ForEach-Object { Add-Content -Path $logPath -Value "    $($_.title)  (updated $($_.id.last_updated))" }
    } else {
      Log "Warhammer Community baseline recorded ($($items.Count) documents)."
    }
    $state.warcom = $sig; $changed = $true
  }
} catch { Log "Warhammer Community check failed: $($_.Exception.Message)" }

if (-not $changed) { Log "No upstream changes." }
New-Item -ItemType Directory -Force -Path (Split-Path $statePath -Parent) | Out-Null
($state | ConvertTo-Json) | Set-Content -Encoding UTF8 $statePath

# Register (run once, from an elevated or normal prompt):
#   schtasks /create /tn "Strategium Update Watch" /sc daily /st 09:30 ^
#     /tr "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File \"C:\Users\homod\OneDrive\The Strategium\Wh40k-data\tools\Watch-Updates.ps1\""