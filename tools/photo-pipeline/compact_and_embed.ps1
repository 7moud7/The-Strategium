# Compact unit-images.json (gw: prefix for warhammer CDN URLs) and embed it
# into thestrategium.html as window.UNIT_IMAGES_DEFAULT.
$ErrorActionPreference = 'Stop'
$dataDir = "C:\Users\homod\OneDrive\The Strategium\Wh40k-data\WH40K\Data"
$html = "C:\Users\homod\OneDrive\The Strategium\Wh40k-data\App\thestrategium.html"
$CDN = "https://www.warhammer.com/app/resources/catalog/product/920x950/"

$m = Get-Content "$dataDir\unit-images.json" -Raw | ConvertFrom-Json
$out = [ordered]@{}
foreach ($f in $m.PSObject.Properties) {
  $fm = [ordered]@{}
  foreach ($u in $f.Value.PSObject.Properties) {
    $v = $u.Value
    if ($v.StartsWith($CDN)) { $v = "gw:" + $v.Substring($CDN.Length) }
    $fm[$u.Name] = $v
  }
  $out[$f.Name] = $fm
}
$json = $out | ConvertTo-Json -Depth 4 -Compress
[IO.File]::WriteAllText("$dataDir\unit-images.json", $json, (New-Object Text.UTF8Encoding($false)))
Write-Host "unit-images.json compacted: $([Math]::Round($json.Length/1KB))KB"

$START = "<!--UNIT_IMAGES_DEFAULT_START-->"
$END = "<!--UNIT_IMAGES_DEFAULT_END-->"
$doc = [IO.File]::ReadAllText($html, [Text.Encoding]::UTF8)
$block = "$START<script>/* AUTO-GENERATED unit->photo baseline (see WH40K/Data/unit-images.json) */window.UNIT_IMAGES_DEFAULT=$json;</script>$END"
$si = $doc.IndexOf($START); $ei = $doc.IndexOf($END)
if ($si -ge 0 -and $ei -gt $si) {
  $doc = $doc.Substring(0, $si) + $block + $doc.Substring($ei + $END.Length)
} else {
  $idx = $doc.IndexOf("<style>")
  if ($idx -lt 0) { throw "anchor not found" }
  $doc = $doc.Substring(0, $idx) + $block + "`n" + $doc.Substring($idx)
}
[IO.File]::WriteAllText($html, $doc, (New-Object Text.UTF8Encoding($false)))
Write-Host "Embedded into HTML. New size: $([Math]::Round($doc.Length/1KB))KB"
