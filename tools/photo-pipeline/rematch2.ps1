# Phase B2: last algorithmic pass - trigram candidate filter + prefix AND
# suffix edit distance (handles fragments missing their first word or letters).
$ErrorActionPreference = 'Stop'
$scratch = $PSScriptRoot
$dataDir = "C:\Users\homod\OneDrive\The Strategium\Wh40k-data\WH40K\Data\Unit Data"

function Norm([string]$s) {
  if (-not $s) { return "" }
  $s = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne 'NonSpacingMark') { [void]$sb.Append($ch) }
  }
  (($sb.ToString().ToUpperInvariant()) -replace '[^A-Z0-9]+', ' ').Trim()
}
function Lev([string]$a, [string]$b) {
  $n = $a.Length; $m = $b.Length
  if ($n -eq 0) { return $m }; if ($m -eq 0) { return $n }
  $prev = 0..$m; $cur = New-Object int[] ($m + 1)
  for ($i = 1; $i -le $n; $i++) {
    $cur[0] = $i
    for ($j = 1; $j -le $m; $j++) {
      $cost = if ($a[$i-1] -eq $b[$j-1]) { 0 } else { 1 }
      $cur[$j] = [Math]::Min([Math]::Min($cur[$j-1] + 1, $prev[$j] + 1), $prev[$j-1] + $cost)
    }
    $tmp = $prev; $prev = $cur; $cur = $tmp
  }
  $prev[$m]
}
function Trigrams([string]$s) {
  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  $t = $s -replace ' ', ''
  for ($i = 0; $i -le $t.Length - 3; $i++) { [void]$set.Add($t.Substring($i, 3)) }
  ,$set
}

$index = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("$dataDir\index.json")) | ConvertFrom-Json
$all = @()
foreach ($fp in $index.PSObject.Properties) {
  $doc = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("$dataDir\$($fp.Value.file)")) | ConvertFrom-Json
  foreach ($u in @($doc.units)) {
    if ($u.id -and $u.name) {
      $clean = ($u.name -replace '<[^>]+>','')
      $n = Norm $clean
      $all += [pscustomobject]@{ fid = $fp.Name; id = $u.id; name = $clean; norm = $n; tri = (Trigrams $n) }
    }
  }
}

function CleanFrag([string]$h) {
  $f = $h -replace '\.{2,}.*$', ''
  $f = $f -replace '(?i)^[<c(&\s]+', ''
  $f = ($f -split '\s+' | Where-Object { $_ -notmatch '^[QO@]$' }) -join ' '
  return $f.Trim()
}

function Fuzzy2([string]$frag, [string]$ctxFid, [bool]$truncated) {
  $fn = Norm $frag
  if ($fn.Length -lt 4) { return $null }
  $ftri = Trigrams $fn
  $best = $null; $bestScore = 999.0
  foreach ($u in $all) {
    # trigram overlap prefilter
    $shared = 0
    foreach ($t in $ftri) { if ($u.tri.Contains($t)) { $shared++ } }
    if ($ftri.Count -gt 0 -and ($shared / $ftri.Count) -lt 0.34) { continue }
    $L = [Math]::Min($fn.Length, $u.norm.Length)
    $dPre = Lev $fn.Substring(0, $L) $u.norm.Substring(0, $L)
    $dSuf = Lev $fn.Substring($fn.Length - $L) $u.norm.Substring($u.norm.Length - $L)
    $dFull = Lev $fn $u.norm
    $rel = [Math]::Min([Math]::Min($dPre, $dSuf) / [Math]::Max(4, $L), $dFull / [Math]::Max(4, [Math]::Max($fn.Length, $u.norm.Length)))
    # a truncated header can't be judged on suffix; skip suffix if "..." present
    if ($truncated) { $rel = [Math]::Min($dPre / [Math]::Max(4, $L), $dFull / [Math]::Max(4, [Math]::Max($fn.Length, $u.norm.Length))) }
    $score = $rel + $(if ($u.fid -eq $ctxFid) { -0.12 } else { 0 })
    if ($score -lt $bestScore) { $bestScore = $score; $best = [pscustomobject]@{ fid = $u.fid; u = $u; rel = $rel } }
  }
  if ($best -and $best.rel -le 0.34) { return $best }
  return $null
}

$rows = @(Import-Csv (Join-Path $scratch "manifest.csv"))
# thread context: nearest preceding known faction
$fixed = 0
for ($i = 0; $i -lt $rows.Count; $i++) {
  $r = $rows[$i]
  if ($r.type -in @('unit','cover')) { continue }
  $ctx = ''
  for ($j = $i - 1; $j -ge 0; $j--) { if ($rows[$j].fid) { $ctx = $rows[$j].fid; break } }
  $frag = CleanFrag $r.header
  if (-not $frag) { continue }
  $m = Fuzzy2 $frag $ctx ($r.header -match '\.{2,}')
  if ($m) {
    $r.type = 'unit'; $r.fid = $m.fid; $r.unitId = $m.u.id; $r.unitName = $m.u.name
    $r.note = "fuzzy2 rel=$([Math]::Round($m.rel,2))"
    $fixed++
  }
}
$rows | Export-Csv (Join-Path $scratch "manifest.csv") -NoTypeInformation -Encoding UTF8
$sum = $rows | Group-Object type | ForEach-Object { "$($_.Name): $($_.Count)" }
Write-Host "Fixed $fixed more. Now: $($sum -join ' | ')"
Write-Host "--- fuzzy2 matches (verify):"
$rows | Where-Object note -like 'fuzzy2*' | ForEach-Object { "  {0,-28} => {1} [{2}] {3}" -f $_.header, $_.unitName, $_.fid, $_.note } | Write-Host
Write-Host "--- still unmatched (non-empty header):"
$rows | Where-Object { $_.type -notin @('unit','cover') -and (CleanFrag $_.header) } | ForEach-Object { "  {0} :: {1}" -f $_.file, $_.header } | Write-Host
Write-Host "--- empty header files:"
($rows | Where-Object { $_.type -notin @('unit','cover') -and -not (CleanFrag $_.header) } | Measure-Object).Count