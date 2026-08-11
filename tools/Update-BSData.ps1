# -- Update-BSData.ps1 ---------------------------------------------------------
# Live BSData pipeline (see TSKB "91 Data Sources" / "92 Live Links").
#
# BSData (github.com/BSData) publishes .cat catalogue XML for most GW systems.
# This tool: (1) checks each registered system's repo for new commits (live
# freshness), (2) downloads the catalogues, (3) standardises them into The
# Strategium's universal unit JSON shape:
#
#   <SystemDir>/Data/<faction-slug>.json
#     { id, name, source, battleTraits: [...], units: [ {
#         id, name, stats{...}, keywords[], weapons[], abilities[],
#         points, unitSize } ] }
#   <SystemDir>/Data/index.json   { factionId: {name, file, units} }
#
# Profile-type mapping is heuristic and game-agnostic: "Unit"-like profiles
# become stats, "*Weapon*" profiles become weapons, "Abilit*" profiles become
# abilities; anything else lands in the unit's raw profiles. Catalogue-level
# rules become battleTraits. Within-file links only (BSData cross-file imports
# are not resolved; AoS "* - Library.cat" files are self-contained).
#
#   powershell -File .\Update-BSData.ps1 -System aos-4e -CheckOnly
#   powershell -File .\Update-BSData.ps1 -System aos-4e            # fetch+convert
#
param(
  [Parameter(Mandatory=$true)][string]$System,
  [switch]$CheckOnly,
  [string[]]$OnlyFiles = @()      # limit conversion to specific catalogue names
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# system id -> BSData repo + output folder (relative to repo root)
$Registry = @{
  'aos-4e'             = @{ repo='BSData/age-of-sigmar-4th';            out='AoS' }
  'wh40k-10e'          = @{ repo='BSData/wh40k-10e';                    out='WH40K-BSData' }
  'wh40k-11e'          = @{ repo='BSData/wh40k-11e';                    out='WH40K-11e' }
  'kill-team'          = @{ repo='BSData/wh40k-killteam';               out='KillTeam' }
  'horus-heresy-3e'    = @{ repo='BSData/horus-heresy-3rd-edition';     out='HorusHeresy' }
  'legions-imperialis' = @{ repo='BSData/Horus-Heresy-Legions-Imperialis'; out='LegionsImperialis' }
  'bloodbowl'          = @{ repo='BSData/bloodbowl-third-season';       out='BloodBowl' }
  'warcry'             = @{ repo='BSData/warhammer-age-of-sigmar-warcry'; out='Warcry' }
  'adeptus-titanicus'  = @{ repo='BSData/adeptus-titanicus';            out='AdeptusTitanicus' }
}
if (-not $Registry.ContainsKey($System)) {
  throw "Unknown system '$System'. Known: $($Registry.Keys -join ', ')"
}
$repoRoot = Split-Path $PSScriptRoot -Parent
$cfg      = $Registry[$System]
$cacheDir = Join-Path (Split-Path $repoRoot -Parent) "Reference\BSData\$System"
$dataDir  = Join-Path $repoRoot "$($cfg.out)\Data"
$revFile  = Join-Path $cacheDir ".revision"
$UA = "TheStrategium-UpdateBSData"

function Api([string]$path) {
  Invoke-RestMethod -Uri "https://api.github.com/$path" -UserAgent $UA
}

# -- 1. freshness check --------------------------------------------------------
$head = (Api "repos/$($cfg.repo)/commits?per_page=1")[0]
$liveRev  = $head.sha.Substring(0,12)
$liveDate = $head.commit.committer.date
$localRev = if (Test-Path $revFile) { (Get-Content $revFile -First 1).Trim() } else { "(none)" }
Write-Output "[$System] $($cfg.repo)  live=$liveRev ($liveDate)  local=$localRev"
if ($CheckOnly) {
  if ($liveRev -ne $localRev) { Write-Output "UPDATE AVAILABLE" } else { Write-Output "up to date" }
  return
}
if ($liveRev -eq $localRev -and $OnlyFiles.Count -eq 0 -and (Test-Path $dataDir)) {
  Write-Output "Already at live revision - nothing to do."; return
}

# -- 2. download catalogues ----------------------------------------------------
if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Force $cacheDir | Out-Null }
if (-not (Test-Path $dataDir))  { New-Item -ItemType Directory -Force $dataDir  | Out-Null }
$files = Api "repos/$($cfg.repo)/contents" | Where-Object { $_.name -like '*.cat' }
if ($OnlyFiles.Count -gt 0) {
  $files = $files | Where-Object { $n = $_.name; ($OnlyFiles | Where-Object { $n -like "*$_*" }).Count -gt 0 }
}
Write-Output "Downloading $($files.Count) catalogues..."
foreach ($f in $files) {
  $dest = Join-Path $cacheDir $f.name
  Invoke-WebRequest -Uri $f.download_url -OutFile $dest -UserAgent $UA -UseBasicParsing
}

# -- 3. standardise ------------------------------------------------------------
function Slug([string]$name) {
  $s = $name.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}',''
  return (($s.ToLower() -replace '[^a-z0-9]+','-').Trim('-'))
}
function CharsOf($profile, $ns) {
  $h = [ordered]@{}
  foreach ($c in $profile.SelectNodes(".//*[local-name()='characteristic']")) {
    $h[$c.GetAttribute('name')] = $c.InnerText.Trim()
  }
  return $h
}

$index = [ordered]@{}
foreach ($f in (Get-ChildItem $cacheDir -Filter '*.cat')) {
  $xml = New-Object Xml.XmlDocument
  $xml.Load($f.FullName)
  $cat = $xml.DocumentElement
  $facName = $cat.GetAttribute('name') -replace ' - Library$',''
  $facId   = Slug $facName

  # catalogue-level rules -> battleTraits
  $traits = @()
  foreach ($r in $cat.SelectNodes("./*[local-name()='sharedRules']/*[local-name()='rule'] | ./*[local-name()='rules']/*[local-name()='rule']")) {
    $desc = $r.SelectSingleNode("./*[local-name()='description']")
    $traits += [ordered]@{ name = $r.GetAttribute('name'); effect = if ($desc) { $desc.InnerText.Trim() } else { '' } }
  }

  # every selectionEntry of type unit/model with profiles
  $units = @()
  foreach ($se in $cat.SelectNodes(".//*[local-name()='selectionEntry'][@type='unit' or @type='model']")) {
    $profiles = $se.SelectNodes(".//*[local-name()='profile']")
    if ($profiles.Count -eq 0) { continue }
    $stats = $null; $weapons = @(); $abilities = @(); $other = @()
    foreach ($p in $profiles) {
      $ptype = $p.GetAttribute('typeName'); $chars = CharsOf $p
      if (-not $stats -and ($ptype -eq 'Unit' -or $ptype -match '^(Model|Operative|Fighter|Player|Knight|Titan)')) {
        $stats = $chars
      } elseif ($ptype -match 'Weapon') {
        $w = [ordered]@{ name = $p.GetAttribute('name'); type = $ptype }
        foreach ($k in $chars.Keys) { $w[$k] = $chars[$k] }
        $weapons += $w
      } elseif ($ptype -match '^Abilit|^Rule|Ability') {
        $a = [ordered]@{ name = $p.GetAttribute('name'); type = $ptype }
        foreach ($k in $chars.Keys) { $a[$k] = $chars[$k] }
        $abilities += $a
      } else {
        $other += [ordered]@{ name = $p.GetAttribute('name'); type = $ptype; chars = $chars }
      }
    }
    $kw = @()
    foreach ($cl in $se.SelectNodes("./*[local-name()='categoryLinks']/*[local-name()='categoryLink']")) {
      $kw += $cl.GetAttribute('name')
    }
    $pts = $null
    foreach ($c in $se.SelectNodes("./*[local-name()='costs']/*[local-name()='cost']")) {
      $v = 0.0
      if ([double]::TryParse($c.GetAttribute('value'), [ref]$v) -and $v -gt 0) { $pts = [int]$v }
    }
    $u = [ordered]@{
      id = $se.GetAttribute('id'); name = $se.GetAttribute('name')
      stats = $stats; keywords = $kw; weapons = $weapons; abilities = $abilities
      points = $pts
    }
    if ($other.Count -gt 0) { $u['profiles'] = $other }
    $units += $u
  }
  if ($units.Count -eq 0) { continue }

  $doc = [ordered]@{
    id = $facId; name = $facName; source = $cfg.repo; revision = $liveRev
    battleTraits = $traits; units = $units
  }
  $outFile = Join-Path $dataDir "$facId.json"
  [IO.File]::WriteAllText($outFile, ($doc | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
  $index[$facId] = [ordered]@{ name = $facName; file = "$facId.json"; units = $units.Count }
  Write-Output ("  {0}: {1} units" -f $facName, $units.Count)
}

[IO.File]::WriteAllText((Join-Path $dataDir 'index.json'), ($index | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
Set-Content -Path $revFile -Value $liveRev
Write-Output "Done. Revision $liveRev recorded. Push to GitHub, then re-run the Supabase ingest functions."
