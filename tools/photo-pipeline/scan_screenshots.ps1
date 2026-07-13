# Phase A: scan all screenshots -> manifest.csv (no files are modified).
# For each: OCR the header title, detect the photo band, classify as faction
# cover or unit datasheet, and match to the app's unit lists.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Drawing

$srcDir = "C:\Users\homod\OneDrive\The Strategium\Warhammer 40K Units"
$dataDir = "C:\Users\homod\OneDrive\The Strategium\Wh40k-data\WH40K\Data\Unit Data"
$outCsv = Join-Path $PSScriptRoot "manifest.csv"

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
  Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($WinRtTask, $ResultType) {
  $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
  $netTask = $asTask.Invoke($null, @($WinRtTask))
  $netTask.Wait(-1) | Out-Null
  $netTask.Result
}
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType=WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()

function Norm([string]$s) {
  if (-not $s) { return "" }
  $s = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne 'NonSpacingMark') { [void]$sb.Append($ch) }
  }
  (($sb.ToString().ToUpperInvariant()) -replace '[^A-Z0-9]+', ' ').Trim()
}

# ── unit lists ──
$index = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("$dataDir\index.json")) | ConvertFrom-Json
$factions = @{}   # fid -> @{name; units=@(@{id;name;norm})}
foreach ($fp in $index.PSObject.Properties) {
  $doc = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("$dataDir\$($fp.Value.file)")) | ConvertFrom-Json
  $units = @()
  foreach ($u in @($doc.units)) {
    if ($u.id -and $u.name) { $units += [pscustomobject]@{ id = $u.id; name = ($u.name -replace '<[^>]+>',''); norm = (Norm $u.name) } }
  }
  $factions[$fp.Name] = [pscustomobject]@{ name = $fp.Value.name; norm = (Norm $fp.Value.name); units = $units }
}
# cover-name aliases -> faction id ("CODEX BLOOD ANGELS" lives inside SM, etc.)
$aliases = @{
  'BLOOD ANGELS'='SM'; 'DARK ANGELS'='SM'; 'SPACE WOLVES'='SM'; 'BLACK TEMPLARS'='SM';
  'DEATHWATCH'='SM'; 'ULTRAMARINES'='SM'; 'WHITE SCARS'='SM'; 'IRON HANDS'='SM';
  'SALAMANDERS'='SM'; 'RAVEN GUARD'='SM'; 'IMPERIAL FISTS'='SM'; 'SPACE MARINES'='SM';
  'AGENTS OF THE IMPERIUM'='AoI'; 'ADEPTUS ASTARTES'='SM'; 'DAEMONS'='CD'; 'DRUKARI'='DRU'
}

function OcrHeaderText([string]$path) {
  $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
  $stream = Await ($file.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
  $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bmp = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $r = Await ($engine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
  $h = $bmp.PixelHeight
  $stream.Dispose()
  $words = @()
  foreach ($line in $r.Lines) {
    foreach ($w in $line.Words) {
      $y = $w.BoundingRect.Y
      if ($y -ge ($h * 0.03) -and $y -le ($h * 0.12) -and $w.BoundingRect.Height -gt ($h * 0.012)) { $words += $w }
    }
  }
  (($words | Sort-Object { $_.BoundingRect.X } | ForEach-Object Text) -join ' ')
}

# photo band via 90px-wide thumbnail brightness scan
function DetectBand([string]$path) {
  $img = [System.Drawing.Bitmap]::FromFile($path)
  try {
    $tw = 90; $th = [int]($img.Height * ($tw / $img.Width))
    $thumb = New-Object System.Drawing.Bitmap $tw, $th
    $g = [System.Drawing.Graphics]::FromImage($thumb)
    $g.InterpolationMode = 'HighQualityBilinear'
    $g.DrawImage($img, 0, 0, $tw, $th)
    $g.Dispose()
    $scale = $img.Height / $th
    $rowStats = for ($y = 0; $y -lt $th; $y++) {
      $sum = 0.0; $sumSq = 0.0; $n = 0
      for ($x = 2; $x -lt $tw - 2; $x += 2) {
        $c = $thumb.GetPixel($x, $y)
        $lum = (0.3 * $c.R + 0.59 * $c.G + 0.11 * $c.B)
        $sum += $lum; $sumSq += $lum * $lum; $n++
      }
      $mean = $sum / $n
      $var = [Math]::Max(0, ($sumSq / $n) - ($mean * $mean))
      [pscustomobject]@{ mean = $mean; sd = [Math]::Sqrt($var) }
    }
    $thumb.Dispose()
    # search below the header (~11.5% of height) for the first light/varied run
    $start = [int]($th * 0.115); $bandStart = -1; $bandEnd = -1
    for ($y = $start; $y -lt $th; $y++) {
      $r0 = $rowStats[$y]
      $isPhoto = ($r0.mean -gt 60 -or $r0.sd -gt 28)
      if ($bandStart -lt 0) {
        if ($isPhoto) { $bandStart = $y }
      } elseif (-not $isPhoto) { $bandEnd = $y; break }
    }
    if ($bandStart -lt 0) { return $null }
    if ($bandEnd -lt 0) { $bandEnd = $th - 1 }
    [pscustomobject]@{ top = [int]($bandStart * $scale); bottom = [int]($bandEnd * $scale); height = $img.Height; width = $img.Width }
  } finally { $img.Dispose() }
}

function MatchUnit([string]$frag, [string]$ctxFid) {
  $f = ($frag -replace '\.{2,}\s*$', '').Trim()   # strip trailing ellipsis
  $fn = Norm $f
  if ($fn.Length -lt 3) { return $null }
  $pools = @()
  if ($ctxFid -and $factions.ContainsKey($ctxFid)) { $pools += ,@($ctxFid) }
  $pools += ,@($factions.Keys | Where-Object { $_ -ne $ctxFid })
  foreach ($pool in $pools) {
    $hits = @()
    foreach ($fid in $pool) {
      foreach ($u in $factions[$fid].units) {
        if ($u.norm -eq $fn) { $hits += [pscustomobject]@{ fid=$fid; u=$u; score=3 } }
        elseif ($u.norm.StartsWith($fn)) { $hits += [pscustomobject]@{ fid=$fid; u=$u; score=2 } }
        elseif ($fn.StartsWith($u.norm)) { $hits += [pscustomobject]@{ fid=$fid; u=$u; score=1 } }
      }
    }
    if ($hits.Count) {
      $best = $hits | Sort-Object { -$_.score }, { $_.u.norm.Length } | Select-Object -First 1
      return $best
    }
  }
  return $null
}

function MatchFaction([string]$frag) {
  $fn = Norm ($frag -replace '\.{2,}\s*$', '' -replace '(?i)codex|index', '')
  if ($fn.Length -lt 4) { return $null }
  foreach ($k in $aliases.Keys) { if ($fn.StartsWith($k) -or $k.StartsWith($fn)) { return $aliases[$k] } }
  foreach ($fid in $factions.Keys) {
    $n = $factions[$fid].norm
    if ($n -eq $fn -or $n.StartsWith($fn) -or $fn.StartsWith($n)) { return $fid }
  }
  # try word-level containment (handles mid-name truncation like ADEPTA SOROR)
  foreach ($fid in $factions.Keys) {
    $n = $factions[$fid].norm
    $shared = @(($fn -split ' ') | Where-Object { $_.Length -ge 4 -and $n.Contains($_) })
    if ($shared.Count -ge 1 -and ($fn -split ' ')[0].Length -ge 4 -and $n.Contains(($fn -split ' ')[0])) { return $fid }
  }
  return $null
}

# ── main loop ──
$rows = New-Object System.Collections.Generic.List[object]
$ctxFid = ''
$files = Get-ChildItem $srcDir -File -Filter *.jpg | Sort-Object Name
$i = 0
foreach ($f in $files) {
  $i++
  if ($i % 25 -eq 0) { Write-Host "  $i / $($files.Count)" }
  $hdr = ''; $band = $null
  try { $hdr = OcrHeaderText $f.FullName } catch {}
  try { $band = DetectBand $f.FullName } catch {}
  $hdrClean = ($hdr -replace '^[<c(&\s]+', '').Trim()
  $type = 'unknown'; $fid = ''; $unitId = ''; $unitName = ''; $note = ''
  $isCover = ($hdrClean -match '(?i)codex|index')
  if (-not $isCover) {
    $m = MatchUnit $hdrClean $ctxFid
    if ($m) {
      $type = 'unit'; $fid = $m.fid; $unitId = $m.u.id; $unitName = $m.u.name
      if ($ctxFid -and $m.fid -ne $ctxFid) { $note = "outside context $ctxFid" }
    } else {
      # maybe a cover whose CODEX word was missed
      $ffid = MatchFaction $hdrClean
      if ($ffid) { $type = 'cover'; $fid = $ffid; $ctxFid = $ffid }
      else { $type = 'unknown'; $note = 'no match' }
    }
  } else {
    $ffid = MatchFaction $hdrClean
    if ($ffid) { $type = 'cover'; $fid = $ffid; $ctxFid = $ffid }
    else { $type = 'cover?'; $note = 'faction not matched' }
  }
  $rows.Add([pscustomobject]@{
    file = $f.Name; header = $hdrClean; type = $type; fid = $fid
    unitId = $unitId; unitName = $unitName
    bandTop = if ($band) { $band.top } else { '' }
    bandBottom = if ($band) { $band.bottom } else { '' }
    note = $note
  })
}
$rows | Export-Csv $outCsv -NoTypeInformation -Encoding UTF8
$sum = $rows | Group-Object type | ForEach-Object { "$($_.Name): $($_.Count)" }
Write-Host ("Done. " + ($sum -join ' | '))
Write-Host "Manifest: $outCsv"