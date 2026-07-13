# Task 11: swap the repo's photo system over to the user's new unit photos.
# 1. copy organized photos into WH40K/Images/Units/<fid>/<unitId>.jpg
# 2. covers into WH40K/Images/Covers/
# 3. delete the old SKU photo trees (Imperium / Legions of Chaos / Xenos)
# 4. rebuild images-index.json and unit-images.json (keep gw: CDN fallbacks
#    for units that have no new photo)
$ErrorActionPreference = 'Stop'
$scratch = $PSScriptRoot
$srcDir = "C:\Users\homod\OneDrive\The Strategium\Warhammer 40K Units"
$repo = "C:\Users\homod\OneDrive\The Strategium\Wh40k-data"
$imgDir = "$repo\WH40K\Images"
$dataDir = "$repo\WH40K\Data"
$illegal = '[\\/:*?"<>|]'

$index = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("$dataDir\Unit Data\index.json")) | ConvertFrom-Json
$facName = @{}
foreach ($fp in $index.PSObject.Properties) { $facName[$fp.Name] = ($fp.Value.name -replace $illegal, '') }

$manifest = Import-Csv (Join-Path $scratch "manifest.csv")

# ── 1. units ──
$copied = 0; $missing = 0
$firstSeen = @{}
$newMap = @{}   # fid -> @{ uid -> "Units/<fid>/<uid>.jpg" }
foreach ($row in ($manifest | Where-Object { $_.type -eq 'unit' -and $_.fid -and $_.unitId })) {
  $key = "$($row.fid)|$($row.unitId)"
  if ($firstSeen.ContainsKey($key)) { continue }
  $firstSeen[$key] = $true
  $src = Join-Path $srcDir "$($facName[$row.fid])\$(($row.unitName -replace $illegal,'').Trim()).jpg"
  if (-not (Test-Path $src)) { $missing++; continue }
  $dstRel = "Units/$($row.fid)/$($row.unitId).jpg"
  $dst = Join-Path $imgDir ($dstRel -replace '/', '\')
  New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
  Copy-Item $src $dst -Force
  if (-not $newMap.ContainsKey($row.fid)) { $newMap[$row.fid] = @{} }
  $newMap[$row.fid][$row.unitId] = $dstRel
  $copied++
}
Write-Host "Units copied: $copied (missing sources: $missing)"

# ── 2. covers ──
New-Item -ItemType Directory -Force -Path "$imgDir\Covers" | Out-Null
$coverDone = @{}
$coverCount = 0
foreach ($row in ($manifest | Where-Object { $_.type -eq 'cover' -and $_.fid })) {
  $label = ($row.unitName -replace $illegal, '').Trim()
  $srcName = if ($label) { "_Cover $label.jpg" } else { "_Cover.jpg" }
  $src = Join-Path $srcDir "$($facName[$row.fid])\$srcName"
  if (-not (Test-Path $src)) { continue }
  $dstName = if ($label) { "$($row.fid) - $label.jpg" } else { "$($row.fid).jpg" }
  if ($coverDone.ContainsKey($dstName)) { continue }
  $coverDone[$dstName] = $true
  Copy-Item $src (Join-Path "$imgDir\Covers" $dstName) -Force
  $coverCount++
}
# manually-cropped covers not in manifest flow
foreach ($extra in @(
    @{ src = "Astra Militarum\_Cover.jpg"; dst = "AM.jpg" },
    @{ src = "Space Marines\_Cover Blood Angels.jpg"; dst = "SM - Blood Angels.jpg" },
    @{ src = "Space Marines\_Cover Deathwatch.jpg"; dst = "SM - Deathwatch.jpg" })) {
  $s = Join-Path $srcDir $extra.src
  $d = Join-Path "$imgDir\Covers" $extra.dst
  if ((Test-Path $s) -and -not (Test-Path $d)) { Copy-Item $s $d -Force; $coverCount++ }
}
Write-Host "Covers copied: $coverCount"

# ── 3. remove old photo trees ──
foreach ($old in @('Imperium', 'Legions of Chaos', 'Xenos')) {
  $p = Join-Path $imgDir $old
  if (Test-Path $p) { Remove-Item $p -Recurse -Force -Confirm:$false; Write-Host "Removed $old" }
}

# ── 4a. images-index.json: per-faction list of repo photos (manual picker) ──
$idx = [ordered]@{}
foreach ($fid in ($newMap.Keys | Sort-Object)) {
  $idx[$fid] = @($newMap[$fid].Values | Sort-Object)
}
[IO.File]::WriteAllText("$dataDir\images-index.json", ($idx | ConvertTo-Json -Depth 3 -Compress), (New-Object Text.UTF8Encoding($false)))
Write-Host "images-index.json rebuilt ($($idx.Keys.Count) factions)"

# ── 4b. unit-images.json: new photos first, keep gw: CDN fallback ──
$old = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("$dataDir\unit-images.json")) | ConvertFrom-Json
$out = [ordered]@{}
$stats = @{ new = 0; gw = 0; dropped = 0 }
$allFids = @($index.PSObject.Properties.Name)
foreach ($fid in $allFids) {
  $m = [ordered]@{}
  $oldF = $old.$fid
  $uids = New-Object 'System.Collections.Generic.HashSet[string]'
  if ($newMap.ContainsKey($fid)) { foreach ($k in $newMap[$fid].Keys) { [void]$uids.Add($k) } }
  if ($oldF) { foreach ($p in $oldF.PSObject.Properties) { [void]$uids.Add($p.Name) } }
  foreach ($uid in $uids) {
    if ($newMap.ContainsKey($fid) -and $newMap[$fid].ContainsKey($uid)) {
      $m[$uid] = $newMap[$fid][$uid]; $stats.new++
    } elseif ($oldF -and $oldF.$uid -and $oldF.$uid.StartsWith('gw:')) {
      $m[$uid] = $oldF.$uid; $stats.gw++
    } else {
      $stats.dropped++
    }
  }
  if ($m.Count) { $out[$fid] = $m }
}
[IO.File]::WriteAllText("$dataDir\unit-images.json", ($out | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
Write-Host "unit-images.json: $($stats.new) new photos, $($stats.gw) GW CDN fallbacks, $($stats.dropped) old repo links dropped"