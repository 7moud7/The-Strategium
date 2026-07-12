# -- Update-RulesData.ps1 -----------------------------------------------------
# Live rules update pipeline (see TSKB "91 Data Sources").
#
# 1. Checks Wahapedia's export timestamp against the local copy.
# 2. Downloads the fresh pipe-delimited CSV exports into "..\..\Warhammer data".
# 3. Syncs unit points costs into WH40K/Data/Unit Data/*.json (unit.id is the
#    Wahapedia datasheet_id), reporting every change it makes.
#
# Full datasheet text/ability changes still need a conversion pass; points are
# what balance dataslates mostly touch and what list-building correctness
# depends on.
#
#   powershell -ExecutionPolicy Bypass -File .\Update-RulesData.ps1 [-CheckOnly]

param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo   = Split-Path $PSScriptRoot -Parent
$csvDir = Join-Path (Split-Path $repo -Parent) "Warhammer data"
$dataDir = Join-Path $repo "WH40K\Data\Unit Data"
$base = "https://wahapedia.ru/wh40k10ed/"
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

function FetchText([string]$name) {
  (Invoke-WebRequest -Uri ($base + $name) -UserAgent $UA -UseBasicParsing).Content
}

# -- 1. freshness check --
$liveStamp = ((FetchText "Last_update.csv") -split "`n" | Select-Object -Skip 1 -First 1).Trim().TrimEnd('|')
$localStamp = ""
$lu = Join-Path $csvDir "Last_update.csv"
if (Test-Path $lu) {
  $localStamp = ((Get-Content $lu | Select-Object -Skip 1 -First 1) -replace '\|','').Trim()
}
Write-Host "Wahapedia export: $liveStamp"
Write-Host "Local copy:       $localStamp"
if ($liveStamp -eq $localStamp) { Write-Host "Data is current."; if (-not $CheckOnly) { Write-Host "(nothing to do)" }; }
if ($CheckOnly) { return }

# -- 2. refresh CSVs --
$files = Get-ChildItem $csvDir -Filter *.csv | Select-Object -ExpandProperty Name
Write-Host "Downloading $($files.Count) CSV exports..."
foreach ($f in $files) {
  try {
    $bytes = (Invoke-WebRequest -Uri ($base + $f) -UserAgent $UA -UseBasicParsing).Content
    if ($bytes -is [string]) { $bytes = [Text.Encoding]::UTF8.GetBytes($bytes) }
    [IO.File]::WriteAllBytes((Join-Path $csvDir $f), $bytes)
  } catch { Write-Warning "  $f failed: $($_.Exception.Message)" }
}
Write-Host "CSVs refreshed."

# -- 3. sync points into faction JSON --
$costCsv = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $csvDir "Datasheets_models_cost.csv")))
$costs = @{}
foreach ($line in ($costCsv -split "`r?`n" | Select-Object -Skip 1)) {
  if (-not $line.Trim()) { continue }
  $p = $line.Split('|')
  if ($p.Count -lt 4) { continue }
  $id = $p[0].Trim([char]0xFEFF).Trim()
  if (-not $costs.ContainsKey($id)) { $costs[$id] = New-Object System.Collections.ArrayList }
  [void]$costs[$id].Add(@{ line = [int]$p[1]; description = $p[2]; cost = $p[3] })
}
Write-Host "Parsed costs for $($costs.Count) datasheets."

$totalChanged = 0
foreach ($file in Get-ChildItem $dataDir -Filter *.json) {
  if ($file.Name -eq 'index.json') { continue }
  $doc = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($file.FullName)) | ConvertFrom-Json
  if (-not $doc.units) { continue }
  $changed = @()
  foreach ($u in $doc.units) {
    if (-not $u.id -or -not $costs.ContainsKey($u.id)) { continue }
    $fresh = @($costs[$u.id] | Sort-Object { $_.line } | ForEach-Object {
      [pscustomobject]@{ description = $_.description; cost = $_.cost } })
    $oldSig = (@($u.costs) | ForEach-Object { "$($_.description)=$($_.cost)" }) -join ';'
    $newSig = ($fresh | ForEach-Object { "$($_.description)=$($_.cost)" }) -join ';'
    if ($oldSig -ne $newSig) {
      $changed += "  $($u.name): [$oldSig] -> [$newSig]"
      $u.costs = $fresh
    }
  }
  if ($changed.Count) {
    $json = $doc | ConvertTo-Json -Depth 64 -Compress
    [IO.File]::WriteAllText($file.FullName, $json, (New-Object Text.UTF8Encoding($false)))
    Write-Host "$($file.Name): $($changed.Count) unit(s) repointed"
    $changed | ForEach-Object { Write-Host $_ }
    $totalChanged += $changed.Count
  }
}
Write-Host ""
Write-Host "Done. $totalChanged unit cost entries updated."
Write-Host "Next: push to GitHub, re-run Build-Obsidian.ps1, re-run Supabase ingest_faction."
