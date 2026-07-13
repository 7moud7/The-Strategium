# Phase C: execute the manifest — crop each screenshot's photo band and
# organize into faction folders. Originals are preserved in _Originals.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$srcDir = "C:\Users\homod\OneDrive\The Strategium\Warhammer 40K Units"
$dataDir = "C:\Users\homod\OneDrive\The Strategium\Wh40k-data\WH40K\Data\Unit Data"
$manifest = Import-Csv (Join-Path $PSScriptRoot "manifest.csv")
$illegal = '[\\/:*?"<>|]'
$MAXW = 800
$INSET = 16

$index = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("$dataDir\index.json")) | ConvertFrom-Json
$facName = @{}
foreach ($fp in $index.PSObject.Properties) { $facName[$fp.Name] = ($fp.Value.name -replace $illegal, '') }

New-Item -ItemType Directory -Force -Path "$srcDir\_Originals", "$srcDir\_Unmatched" | Out-Null

function CropSave([string]$src, [string]$dst, [int]$top, [int]$bottom) {
  $img = [System.Drawing.Bitmap]::FromFile($src)
  try {
    $t = [Math]::Max(0, $top + $INSET)
    $b = [Math]::Min($img.Height, $bottom - $INSET)
    if (($b - $t) -lt 200) { $t = [Math]::Max(0, $top); $b = [Math]::Min($img.Height, $bottom) }
    $w = $img.Width; $h = $b - $t
    $ow = [Math]::Min($MAXW, $w); $oh = [int]($h * ($ow / $w))
    $out = New-Object System.Drawing.Bitmap $ow, $oh
    $g = [System.Drawing.Graphics]::FromImage($out)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $ow, $oh)),
                 (New-Object System.Drawing.Rectangle(0, $t, $w, $h)), 'Pixel')
    $g.Dispose()
    $enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]88)
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    $out.Save($dst, $enc, $ep)
    $out.Dispose()
  } finally { $img.Dispose() }
}

$done = 0; $dupes = 0; $unmatched = 0; $covers = 0
$seen = @{}
foreach ($row in $manifest) {
  $src = Join-Path $srcDir $row.file
  if (-not (Test-Path $src)) { continue }
  $hasBand = ($row.bandTop -ne '' -and $row.bandBottom -ne '' -and ([int]$row.bandBottom - [int]$row.bandTop) -gt 250)
  if ($row.type -in @('unit','named') -and $row.fid -and $hasBand) {
    $fn = $facName[$row.fid]
    $unitFile = ($row.unitName -replace $illegal, '').Trim()
    $key = "$($row.fid)|$unitFile"
    if ($seen.ContainsKey($key)) {
      $dupes++
      $dst = Join-Path $srcDir "$fn\$unitFile ($($seen[$key] + 1)).jpg"
      $seen[$key]++
    } else {
      $seen[$key] = 1
      $dst = Join-Path $srcDir "$fn\$unitFile.jpg"
    }
    CropSave $src $dst ([int]$row.bandTop) ([int]$row.bandBottom)
    Move-Item $src (Join-Path "$srcDir\_Originals" $row.file) -Force
    $done++
  } elseif (($row.type -eq 'cover') -and $row.fid -and $hasBand) {
    $fn = $facName[$row.fid]
    $label = if ($row.unitName) { " $(($row.unitName -replace $illegal, ''))" } else { "" }
    $dst = Join-Path $srcDir "$fn\_Cover$label.jpg"
    if (Test-Path $dst) { $dst = Join-Path $srcDir "$fn\_Cover$label ($((Get-Random -Maximum 999))).jpg" }
    CropSave $src $dst ([int]$row.bandTop) ([int]$row.bandBottom)
    Move-Item $src (Join-Path "$srcDir\_Originals" $row.file) -Force
    $covers++
  } else {
    Move-Item $src (Join-Path "$srcDir\_Unmatched" $row.file) -Force
    $unmatched++
  }
  if ((($done + $covers + $unmatched) % 50) -eq 0) { Write-Host "  processed $($done + $covers + $unmatched)" }
}
Write-Host "Units cropped: $done ($dupes duplicates renamed)"
Write-Host "Covers: $covers"
Write-Host "Unmatched (moved to _Unmatched): $unmatched"