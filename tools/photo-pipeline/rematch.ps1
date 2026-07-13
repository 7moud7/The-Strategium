# Phase B: re-match manifest rows using fuzzy matching (edit distance with
# prefix-truncation, junk-token stripping, and faction context threading).
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

$index = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("$dataDir\index.json")) | ConvertFrom-Json
$factions = @{}
$facNorm = @{}
foreach ($fp in $index.PSObject.Properties) {
  $doc = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("$dataDir\$($fp.Value.file)")) | ConvertFrom-Json
  $units = @()
  foreach ($u in @($doc.units)) {
    if ($u.id -and $u.name) {
      $clean = ($u.name -replace '<[^>]+>','')
      $units += [pscustomobject]@{ id = $u.id; name = $clean; norm = (Norm $clean) }
    }
  }
  $factions[$fp.Name] = $units
  $facNorm[$fp.Name] = Norm $fp.Value.name
}
$aliases = @{
  'BLOOD ANGELS'='SM'; 'DARK ANGELS'='SM'; 'SPACE WOLVES'='SM'; 'BLACK TEMPLARS'='SM';
  'DEATHWATCH'='SM'; 'ULTRAMARINES'='SM'; 'WHITE SCARS'='SM'; 'IRON HANDS'='SM';
  'SALAMANDERS'='SM'; 'RAVEN GUARD'='SM'; 'IMPERIAL FISTS'='SM'; 'SPACE MARINES'='SM';
  'AGENTS OF THE IMPERIUM'='AoI'; 'DAEMONS'='CD'
}

function CleanFrag([string]$h) {
  $f = $h -replace '\.{2,}.*$', ''            # cut at ellipsis
  $f = $f -replace '(?i)^[<c(&\s]+', ''
  $f = ($f -split '\s+' | Where-Object { $_ -notmatch '^[QO@€]$' }) -join ' '   # drop stray icon glyphs
  return $f.Trim()
}

function FuzzyMatch([string]$frag, [string]$ctxFid) {
  $fn = Norm $frag
  if ($fn.Length -lt 4) { return $null }
  $fragTokens = @($fn -split ' ')
  # variants: whole, minus leading token(s) — leading junk like "UOS"/"WN"
  $variants = @($fn)
  if ($fragTokens.Count -ge 2) { $variants += ($fragTokens[1..($fragTokens.Count-1)] -join ' ') }
  if ($fragTokens.Count -ge 3) { $variants += ($fragTokens[2..($fragTokens.Count-1)] -join ' ') }
  $best = $null; $bestScore = 999.0
  foreach ($fid in $factions.Keys) {
    $ctxBonus = if ($fid -eq $ctxFid) { -0.12 } else { 0.0 }
    foreach ($u in $factions[$fid]) {
      # cheap prefilter: any >=5-char token substring either way
      $related = $false
      foreach ($t in $fragTokens) {
        if ($t.Length -ge 5 -and $u.norm.Contains($t)) { $related = $true; break }
      }
      if (-not $related) {
        foreach ($t in ($u.norm -split ' ')) {
          if ($t.Length -ge 5 -and $fn.Contains($t)) { $related = $true; break }
        }
      }
      if (-not $related) { continue }
      foreach ($v in $variants) {
        if ($v.Length -lt 4) { continue }
        $L = [Math]::Min($v.Length, $u.norm.Length)
        # prefix-vs-prefix (handles ... truncation), plus full-vs-full
        $d1 = Lev $v.Substring(0, $L) $u.norm.Substring(0, $L)
        $d2 = Lev $v $u.norm
        $rel = [Math]::Min($d1 / [Math]::Max(4, $L), $d2 / [Math]::Max(4, [Math]::Max($v.Length, $u.norm.Length)))
        $score = $rel + $ctxBonus
        if ($score -lt $bestScore) { $bestScore = $score; $best = [pscustomobject]@{ fid=$fid; u=$u; rel=$rel } }
      }
    }
  }
  if ($best -and $best.rel -le 0.28) { return $best }
  return $null
}

function MatchFactionFuzzy([string]$frag) {
  $fn = Norm ($frag -replace '(?i)c?odex( supplement)?|index', '')
  if ($fn.Length -lt 4) { return $null }
  foreach ($k in $aliases.Keys) {
    if ($fn.StartsWith($k) -or $k.StartsWith($fn) -or (Lev $fn $k) -le 2) { return $aliases[$k] }
  }
  $best = $null; $bd = 999
  foreach ($fid in $facNorm.Keys) {
    $n = $facNorm[$fid]
    $L = [Math]::Min($fn.Length, $n.Length)
    $d = Lev $fn.Substring(0,$L) $n.Substring(0,$L)
    if ($d -lt $bd) { $bd = $d; $best = $fid }
  }
  if ($bd -le [Math]::Ceiling($fn.Length * 0.3)) { return $best }
  return $null
}

$rows = Import-Csv (Join-Path $scratch "manifest.csv")
$ctx = ''
$fixed = 0
foreach ($r in $rows) {
  if ($r.type -eq 'unit' -or $r.type -eq 'cover') { if ($r.fid) { $ctx = $r.fid }; continue }
  $frag = CleanFrag $r.header
  if (-not $frag) { continue }
  if ($frag -match '(?i)odex|ndex|supplement') {
    $ffid = MatchFactionFuzzy $frag
    if ($ffid) { $r.type = 'cover'; $r.fid = $ffid; $r.note = 'fuzzy'; $ctx = $ffid; $fixed++ }
    continue
  }
  $m = FuzzyMatch $frag $ctx
  if ($m) {
    $r.type = 'unit'; $r.fid = $m.fid; $r.unitId = $m.u.id; $r.unitName = $m.u.name
    $r.note = "fuzzy rel=$([Math]::Round($m.rel,2))"
    $ctx = $m.fid; $fixed++
  }
}
$rows | Export-Csv (Join-Path $scratch "manifest.csv") -NoTypeInformation -Encoding UTF8
$sum = $rows | Group-Object type | ForEach-Object { "$($_.Name): $($_.Count)" }
Write-Host "Re-matched $fixed rows. Now: $($sum -join ' | ')"
$still = $rows | Where-Object { $_.type -notin @('unit','cover') }
Write-Host "Remaining unmatched headers:"
$still | Group-Object header | Sort-Object Count -Descending | Select-Object -First 30 Count, Name | Format-Table -AutoSize | Out-String | Write-Host