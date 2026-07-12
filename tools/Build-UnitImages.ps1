# ── Build-UnitImages.ps1 ─────────────────────────────────────────────────────
# Regenerates WH40K/Data/unit-images.json: an automatic unit→photo map giving
# every datasheet an official Games Workshop kit photo.
#
# Sources:
#   1. GW webstore catalogue via its public Algolia search API (the same
#      appId/search-key every visitor's browser uses on warhammer.com).
#   2. WH40K/Data/images-index.json — local repo kit photos named by GW SKU;
#      preferred over CDN links when the matched product's SKU has one.
#
# Matching, two passes per datasheet:
#   pass 1 — exact/variant name and faction-slug matches against the dump;
#   pass 2 — Algolia full-text search for whatever pass 1 missed, accepted
#            only when the hit shares a meaningful name token with the unit.
#
# Output values are either a repo photo path ("Imperium/…/gw-…-0.jpg") or
# "gw:<file>" meaning https://www.warhammer.com/app/resources/catalog/product/920x950/<file>.
#
# After regenerating, re-embed the map into App/thestrategium.html by replacing
# the JSON between <!--UNIT_IMAGES_DEFAULT_START--> and <!--UNIT_IMAGES_DEFAULT_END-->.
#
#   powershell -ExecutionPolicy Bypass -File .\Build-UnitImages.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $root "WH40K\Data"
$work = Join-Path $env:TEMP "gw-catalog-dump"
New-Item -ItemType Directory -Force -Path $work | Out-Null

$APP = "M5ZIQZNQ2H"; $KEY = "92c6a8254f9d34362df8e6d96475e5d8"   # public client-side search key from warhammer.com
$URL = "https://$APP-dsn.algolia.net/1/indexes/prod-lazarus-product-en-gb/query"
$HDR = @{ "X-Algolia-API-Key" = $KEY; "X-Algolia-Application-Id" = $APP }
$CDN = "https://www.warhammer.com/app/resources/catalog/product/920x950/"

function Norm([string]$s) {
  if (-not $s) { return "" }
  $s = $s -replace '<[^>]+>', ' '
  $s = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne 'NonSpacingMark') { [void]$sb.Append($ch) }
  }
  $s = $sb.ToString().ToLowerInvariant()
  $s = $s -replace '&amp;', ' and ' -replace '&', ' and '
  $s = $s -replace "[^a-z0-9]+", ' '
  return ($s.Trim() -replace '\s+', ' ')
}
$STOP = @('of','the','in','with','on','and','a','an','squad','team','unit','mounted','foot')
function Tokens([string]$norm) {
  @($norm -split ' ' | Where-Object { $_ -and $STOP -notcontains $_ } | ForEach-Object { $_.TrimEnd('s') } | Where-Object { $_.Length -gt 2 })
}

# ── 1. dump the full miniatureKit catalogue (price bands beat the 1000-hit cap) ──
Write-Host "Downloading GW catalogue..."
$i = 0
foreach ($f in @("price<25", "price>=25 AND price<32.5", "price>=32.5 AND price<40", "price>=40 AND price<60", "price>=60")) {
  $body = @{ query=""; hitsPerPage=1000; filters="productType:miniatureKit AND ($f)"; attributesToRetrieve=@('name','sku','images','slug'); attributesToHighlight=@() } | ConvertTo-Json -Compress
  Invoke-RestMethod -Uri $URL -Method Post -Headers $HDR -ContentType 'application/json' -Body $body |
    ConvertTo-Json -Depth 6 -Compress | Set-Content -Encoding UTF8 (Join-Path $work "kits_$i.json")
  $i++
}

$products = @()
Get-ChildItem "$work\kits_*.json" | ForEach-Object { $products += (Get-Content $_.FullName -Raw | ConvertFrom-Json).hits }
Write-Host "Products: $($products.Count)"

$byName = @{}; $bySlug = @{}
foreach ($p in $products) {
  $code = $null
  if ($p.sku -match '(\d{11})$') { $code = $Matches[1] }
  $slugNorm = ''
  if ($p.slug) { $slugNorm = Norm (($p.slug -replace '(-\d{4}(-\d+)?)$', '') -replace '-', ' ') }
  $rec = [pscustomobject]@{ name=$p.name; nameNorm=(Norm $p.name); slugNorm=$slugNorm; code=$code; images=$p.images }
  if (-not $byName.ContainsKey($rec.nameNorm)) { $byName[$rec.nameNorm] = @() }
  $byName[$rec.nameNorm] += ,$rec
  if ($slugNorm) {
    if (-not $bySlug.ContainsKey($slugNorm)) { $bySlug[$slugNorm] = @() }
    $bySlug[$slugNorm] += ,$rec
  }
}

# ── 2. local repo photos: SKU code -> repo path ──
$imgIndex = Get-Content "$dataDir\images-index.json" -Raw | ConvertFrom-Json
$codeToPath = @{}
foreach ($prop in $imgIndex.PSObject.Properties) {
  foreach ($path in $prop.Value) {
    if ($path -match 'gw-(\d{11})(-(\d+))?-0\.(jpg|jpeg|png)$') {
      $code = $Matches[1]; $isBase = -not $Matches[3]
      if ($isBase -or -not $codeToPath.ContainsKey($code)) { $codeToPath[$code] = $path }
    }
  }
}
Write-Host "Local photo codes: $($codeToPath.Count)"

function BestImage($images, $code) {
  $imgs = @($images | Where-Object { $_ -match '^/app/resources/catalog/product/920x950/.+\.(jpg|jpeg|png)$' })
  if (-not $imgs) { return $null }
  $own = @($imgs | Where-Object { $code -and $_ -match $code })
  $pool = if ($own) { $own } else { $imgs }
  foreach ($suffix in @('Stock','Feature','Lead','01','1')) {
    $hit = $pool | Where-Object { $_ -match "$suffix\.(jpg|jpeg|png)$" } | Select-Object -First 1
    if ($hit) { return $hit }
  }
  return $pool[0]
}
function PhotoOf($rec) {
  if ($rec.code -and $codeToPath.ContainsKey($rec.code)) { return $codeToPath[$rec.code] }
  $img = BestImage $rec.images $rec.code
  if ($img) { return "gw:" + ($img -replace '^/app/resources/catalog/product/920x950/', '') }
  return $null
}
function PickBest($recs, [string]$facNorm) {
  if ($recs.Count -eq 1) { return $recs[0] }
  $withFac = @($recs | Where-Object { $_.slugNorm.StartsWith($facNorm) })
  if ($withFac) { return $withFac[0] }
  return $recs[0]
}

# ── 3. pass 1: dictionary matching ──
$index = Get-Content "$dataDir\Unit Data\index.json" -Raw | ConvertFrom-Json
$result = [ordered]@{}
foreach ($fprop in $index.PSObject.Properties) {
  $fid = $fprop.Name
  $facNorm = Norm $fprop.Value.name
  $file = "$dataDir\Unit Data\$($fprop.Value.file)"
  if (-not (Test-Path $file)) { continue }
  $units = (Get-Content $file -Raw | ConvertFrom-Json).units
  if (-not $units) { continue }
  $fmap = [ordered]@{}
  foreach ($u in $units) {
    $un = Norm $u.name
    if (-not $un) { continue }
    $cands = $null
    $key = "$facNorm $un"
    if ($bySlug.ContainsKey($key)) { $cands = $bySlug[$key] }
    if (-not $cands -and $byName.ContainsKey($un)) { $cands = $byName[$un] }
    if (-not $cands) {
      $variants = @()
      if ($un -match ' squad$') { $variants += ($un -replace ' squad$', ''); $variants += (($un -replace ' squad$', '') + 's') }
      else { $variants += "$un squad" }
      if ($un -match 's$') { $variants += $un.TrimEnd('s') } else { $variants += "${un}s" }
      $variants += ($un -replace '^\S+ ', '')
      foreach ($v in $variants) {
        if ($v -and $byName.ContainsKey($v)) { $cands = $byName[$v]; break }
        if ($v -and $bySlug.ContainsKey("$facNorm $v")) { $cands = $bySlug["$facNorm $v"]; break }
      }
    }
    if (-not $cands -and $byName.ContainsKey($key)) { $cands = $byName[$key] }
    if ($cands) {
      $photo = PhotoOf (PickBest @($cands) $facNorm)
      if ($photo) { $fmap[$u.id] = $photo }
    }
  }
  $result[$fid] = $fmap
}

# ── 4. pass 2: Algolia full-text search for the rest ──
foreach ($fprop in $index.PSObject.Properties) {
  $fid = $fprop.Name
  $facName = ($fprop.Value.name -replace "’","'")
  $file = "$dataDir\Unit Data\$($fprop.Value.file)"
  if (-not (Test-Path $file)) { continue }
  $units = (Get-Content $file -Raw | ConvertFrom-Json).units
  if (-not $units) { continue }
  $fmap = $result[$fid]
  foreach ($u in $units) {
    if ($fmap.Contains($u.id)) { continue }
    $un = Norm $u.name
    $utok = Tokens $un
    if (-not $utok) { continue }
    $body = @{ query = "$facName $($u.name -replace '<[^>]+>','')"; hitsPerPage = 3; filters = "productType:miniatureKit"; attributesToRetrieve = @('name','sku','images','slug'); attributesToHighlight = @() } | ConvertTo-Json -Compress
    try { $resp = Invoke-RestMethod -Uri $URL -Method Post -Headers $HDR -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) }
    catch { Start-Sleep -Milliseconds 500; continue }
    foreach ($hit in $resp.hits) {
      $htok = Tokens ((Norm $hit.name) + ' ' + (Norm (($hit.slug -replace '(-\d{4}(-\d+)?)$','') -replace '-',' ')))
      if (-not @($utok | Where-Object { $htok -contains $_ })) { continue }
      $code = $null
      if ($hit.sku -match '(\d{11})$') { $code = $Matches[1] }
      $photo = $null
      if ($code -and $codeToPath.ContainsKey($code)) { $photo = $codeToPath[$code] }
      else { $img = BestImage $hit.images $code; if ($img) { $photo = "gw:" + ($img -replace '^/app/resources/catalog/product/920x950/', '') } }
      if ($photo) { $fmap[$u.id] = $photo; break }
    }
  }
  Write-Host ("{0,-5} {1,4}/{2}" -f $fid, $fmap.Count, $units.Count)
}

$total = 0; foreach ($k in $result.Keys) { $total += $result[$k].Count }
Write-Host "TOTAL mapped: $total"
$json = $result | ConvertTo-Json -Depth 4 -Compress
[IO.File]::WriteAllText("$dataDir\unit-images.json", $json, (New-Object Text.UTF8Encoding($false)))
Write-Host "Wrote $dataDir\unit-images.json ($([Math]::Round($json.Length/1KB))KB)"
Write-Host "Remember to re-embed into App/thestrategium.html (UNIT_IMAGES_DEFAULT block)."
