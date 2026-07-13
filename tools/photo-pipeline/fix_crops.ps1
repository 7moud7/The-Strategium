# Re-crop over-tall images (band detector ran into white content areas).
# The app's photo band is ~660-720px tall at 1440w, so cap crops there.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$scratch = $PSScriptRoot
$srcDir = "C:\Users\homod\OneDrive\The Strategium\Warhammer 40K Units"
$repo = "C:\Users\homod\OneDrive\The Strategium\Wh40k-data"
$imgDir = "$repo\WH40K\Images"
$dataDir = "$repo\WH40K\Data"
$illegal = '[\\/:*?"<>|]'
$MAXW = 800; $INSET = 16; $MAXBAND = 736

$index = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("$dataDir\Unit Data\index.json")) | ConvertFrom-Json
$facName = @{}
foreach ($fp in $index.PSObject.Properties) { $facName[$fp.Name] = ($fp.Value.name -replace $illegal, '') }

function CropSave([string]$src, [string]$dst, [int]$top, [int]$bottom) {
  $img = [System.Drawing.Bitmap]::FromFile($src)
  try {
    $t = [Math]::Max(0, $top + $INSET)
    $b = [Math]::Min($img.Height, [Math]::Min($bottom - $INSET, $top + $MAXBAND))
    if (($b - $t) -lt 200) { $b = [Math]::Min($img.Height, $top + $MAXBAND) }
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
    if (Test-Path $dst) { Remove-Item $dst -Force }
    $out.Save($dst, $enc, $ep)
    $out.Dispose()
  } finally { $img.Dispose() }
}

function IsTooTall([string]$path) {
  if (-not (Test-Path $path)) { return $false }
  $img = [System.Drawing.Bitmap]::FromFile($path)
  try { return ($img.Height / $img.Width) -gt 0.55 } finally { $img.Dispose() }
}

$manifest = Import-Csv (Join-Path $scratch "manifest.csv")
$fixed = 0
$seen = @{}
foreach ($row in $manifest) {
  if (-not $row.bandTop -or -not $row.fid) { continue }
  $orig = Join-Path "$srcDir\_Originals" $row.file
  if (-not (Test-Path $orig)) { continue }
  $fn = $facName[$row.fid]
  if ($row.type -in @('unit','named')) {
    $base = ($row.unitName -replace $illegal, '').Trim()
    $key = "$($row.fid)|$base"
    $n = if ($seen.ContainsKey($key)) { $seen[$key] + 1 } else { 1 }
    $seen[$key] = $n
    $local = if ($n -eq 1) { Join-Path $srcDir "$fn\$base.jpg" } else { Join-Path $srcDir "$fn\$base ($n).jpg" }
    if (IsTooTall $local) {
      CropSave $orig $local ([int]$row.bandTop) ([int]$row.bandBottom)
      $fixed++
      if ($n -eq 1 -and $row.type -eq 'unit' -and $row.unitId) {
        $repoDst = Join-Path $imgDir "Units\$($row.fid)\$($row.unitId).jpg"
        if (Test-Path $repoDst) { Copy-Item $local $repoDst -Force }
      }
    }
  } elseif ($row.type -eq 'cover') {
    $label = ($row.unitName -replace $illegal, '').Trim()
    $localName = if ($label) { "_Cover $label.jpg" } else { "_Cover.jpg" }
    $local = Join-Path $srcDir "$fn\$localName"
    if (IsTooTall $local) {
      CropSave $orig $local ([int]$row.bandTop) ([int]$row.bandBottom)
      $fixed++
      $repoName = if ($label) { "$($row.fid) - $label.jpg" } else { "$($row.fid).jpg" }
      $repoDst = Join-Path $imgDir "Covers\$repoName"
      if (Test-Path $repoDst) { Copy-Item $local $repoDst -Force }
    }
  }
}
Write-Host "Re-cropped $fixed over-tall images."