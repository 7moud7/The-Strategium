# ── Build-Obsidian.ps1 ───────────────────────────────────────────────────────
# Generates The Strategium Knowledge Base (TSKB) inside the Obsidian vault at
# "<project>\The Strategium" from the repo's actual game data:
#   - 10 Rules Engine/   one note per core-rules.json section + rules commentary
#   - 20 Mission Engine/ one note per file in WH40K/Rules/Missions|Crusades|Campaigns
#   - 40 Army Intelligence/Factions/  one note per faction (army rule,
#     detachments, enhancements, stratagem index, unit roster with photos)
# Hand-authored system notes (00 System, 30 Battle Engine, 60 Probability,
# 90 Dev Standards, Home) are left untouched — this script only rebuilds the
# data-derived notes, so it is safe to re-run after every data update.
#
#   powershell -ExecutionPolicy Bypass -File .\Build-Obsidian.ps1

$ErrorActionPreference = 'Stop'
$repo  = Split-Path $PSScriptRoot -Parent
$vault = Join-Path (Split-Path $repo -Parent) "The Strategium"
if (-not (Test-Path $vault)) { throw "Vault not found: $vault" }
$tskb = Join-Path $vault "TSKB"
$illegalFsChars = '[\\/:*?"<>|]'   # characters not allowed in note file names

function ReadJson([string]$path) {
  [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path)) | ConvertFrom-Json
}
function CleanText([string]$s) {
  if (-not $s) { return "" }
  $s = $s -replace '<b>|</b>', '**' -replace '<i>|</i>', '*'
  $s = $s -replace '<br\s*/?>', "`n" -replace '<[^>]+>', ' '
  $s = $s -replace '\|', '\|'
  return ($s -replace '[ \t]+', ' ').Trim()
}
function Label([string]$k) {
  $t = ($k -creplace '([A-Z])', ' $1') -replace '[_-]', ' '
  return (Get-Culture).TextInfo.ToTitleCase($t.Trim().ToLower())
}
# Recursive JSON -> markdown
function Render($node, [int]$depth) {
  $out = New-Object System.Collections.Generic.List[string]
  if ($null -eq $node) { return $out }
  if ($node -is [string]) { $out.Add((CleanText $node)); $out.Add(""); return $out }
  if ($node -is [ValueType]) { $out.Add("$node"); $out.Add(""); return $out }
  if ($node -is [System.Collections.IEnumerable] -and $node -isnot [PSCustomObject]) {
    foreach ($item in $node) {
      if ($item -is [string] -or $item -is [ValueType]) { $out.Add("- $(CleanText "$item")") }
      else { foreach ($l in (Render $item $depth)) { $out.Add($l) } }
    }
    $out.Add(""); return $out
  }
  if ($node -is [PSCustomObject]) {
    # name-led objects render their name as a heading
    $props = @($node.PSObject.Properties)
    $nameProp = $props | Where-Object { $_.Name -eq 'name' } | Select-Object -First 1
    if ($nameProp -and $props.Count -gt 1) {
      $h = [Math]::Min(6, [Math]::Max(3, $depth))
      $out.Add(('#' * $h) + " " + (CleanText $nameProp.Value)); $out.Add("")
    }
    foreach ($p in $props) {
      if ($p.Name -eq 'name' -and $nameProp -and $props.Count -gt 1) { continue }
      $v = $p.Value
      if ($null -eq $v) { continue }
      if ($v -is [string] -or $v -is [ValueType]) {
        $out.Add("**$(Label $p.Name):** $(CleanText "$v")"); $out.Add("")
      } else {
        $h = [Math]::Min(6, [Math]::Max(3, $depth))
        $out.Add(('#' * $h) + " $(Label $p.Name)"); $out.Add("")
        foreach ($l in (Render $v ($depth + 1))) { $out.Add($l) }
      }
    }
    return $out
  }
  $out.Add("$node"); return $out
}
function WriteNote([string]$relPath, [string[]]$lines) {
  $full = Join-Path $tskb $relPath
  New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent) | Out-Null
  [IO.File]::WriteAllText($full, ($lines -join "`n"), (New-Object Text.UTF8Encoding($false)))
  Write-Host "  $relPath"
}

# ── 10 Rules Engine ──
Write-Host "Rules Engine..."
$core = ReadJson (Join-Path $repo "WH40K\Rules\core-rules.json")
$order = @{ battleRound=11; commandPhase=12; movementPhase=13; shootingPhase=14; chargePhase=15;
  fightPhase=16; attackSequence=17; keyRules=18; weaponAbilities=19; deploymentAbilities=20;
  stratagems=21; strategicReserves=22; terrain=23; mustering=24; scoring=25; visibility=26;
  dice=27; phaseQuickRef=28; keyDefinitions=29 }
$ruleNotes = @()
foreach ($p in $core.PSObject.Properties) {
  if ($p.Name -eq 'meta') { continue }
  $n = if ($order.ContainsKey($p.Name)) { $order[$p.Name] } else { 39 }
  $title = "$n $(Label $p.Name)"
  $ruleNotes += $title
  $lines = @("---", "tags: [rules-engine]", "source: WH40K/Rules/core-rules.json#$($p.Name)", "---",
    "# $(Label $p.Name)", "", "> Part of [[10 Rules Engine Index]] · regenerate with tools/Build-Obsidian.ps1", "")
  $lines += Render $p.Value 2
  WriteNote "10 Rules Engine\$title.md" $lines
}
$commentary = Join-Path $repo "WH40K\Rules\rules-commentary.json"
if (Test-Path $commentary) {
  $lines = @("---", "tags: [rules-engine]", "source: WH40K/Rules/rules-commentary.json", "---",
    "# Rules Commentary", "", "> Part of [[10 Rules Engine Index]]", "")
  $lines += Render (ReadJson $commentary) 2
  $ruleNotes += "38 Rules Commentary"
  WriteNote "10 Rules Engine\38 Rules Commentary.md" $lines
}
$idx = @("---", "tags: [rules-engine, moc]", "---", "# Rules Engine — Index", "",
  "Every note below is generated from the repo's machine-readable rules data.", "")
$idx += ($ruleNotes | Sort-Object | ForEach-Object { "- [[$_]]" })
WriteNote "10 Rules Engine\10 Rules Engine Index.md" $idx

# ── 20 Mission Engine ──
Write-Host "Mission Engine..."
$missionNotes = @()
foreach ($sub in @('Missions', 'Crusades', 'Campaigns')) {
  $dir = Join-Path $repo "WH40K\Rules\$sub"
  if (-not (Test-Path $dir)) { continue }
  foreach ($f in Get-ChildItem $dir -Filter *.json) {
    $title = "$sub — $((Get-Culture).TextInfo.ToTitleCase(($f.BaseName -replace '[-_]',' ')))"
    $missionNotes += $title
    $lines = @("---", "tags: [mission-engine]", "source: WH40K/Rules/$sub/$($f.Name)", "---",
      "# $title", "", "> Part of [[20 Mission Engine Index]]", "")
    $lines += Render (ReadJson $f.FullName) 2
    WriteNote "20 Mission Engine\$title.md" $lines
  }
}
$idx = @("---", "tags: [mission-engine, moc]", "---", "# Mission Engine — Index", "")
$idx += ($missionNotes | Sort-Object | ForEach-Object { "- [[$_]]" })
WriteNote "20 Mission Engine\20 Mission Engine Index.md" $idx

# ── 40 Army Intelligence ──
Write-Host "Army Intelligence..."
$dataDir = Join-Path $repo "WH40K\Data"
$index = ReadJson (Join-Path $dataDir "Unit Data\index.json")
$imgMap = ReadJson (Join-Path $dataDir "unit-images.json")
$GW = "https://www.warhammer.com/app/resources/catalog/product/920x950/"
$RAW = "https://raw.githubusercontent.com/7moud7/The-Strategium/main/WH40K/Images/"
$facNotes = @()
foreach ($fp in $index.PSObject.Properties) {
  $fid = $fp.Name
  $meta = $fp.Value
  $fdata = ReadJson (Join-Path $dataDir "Unit Data\$($meta.file)")
  $lines = @("---", "tags: [faction]", "faction_id: $fid",
    "source: WH40K/Data/Unit Data/$($meta.file)", "---",
    "# $($meta.name)", "",
    "> Part of [[40 Factions Index]] · $($meta.units) units · $($meta.detachments) detachments · see [[91 Data Sources]]", "")
  if ($fdata.armyRule) {
    $lines += "## Army Rule — $(CleanText $fdata.armyRule.name)"
    $lines += ""
    $lines += (CleanText $fdata.armyRule.rule)
    $lines += ""
  }
  $lines += "## Detachments"
  $lines += ""
  foreach ($det in @($fdata.detachments)) {
    if (-not $det) { continue }
    $lines += "### $(CleanText $det.name)"
    $lines += ""
    foreach ($ab in @($det.abilities)) {
      if (-not $ab) { continue }
      $abText = if ($ab.description) { $ab.description } elseif ($ab.rule) { $ab.rule } else { '' }
      $lines += "**$(CleanText $ab.name):** $(CleanText $abText)"
      $lines += ""
    }
    $enh = @($det.enhancements)
    if ($enh.Count) {
      $lines += "**Enhancements:**"
      foreach ($e in $enh) { $lines += "- **$(CleanText $e.name)** ($($e.cost)pts) — $(CleanText $e.description)" }
      $lines += ""
    }
    $str = @($det.stratagems)
    if ($str.Count) {
      $lines += "**Stratagems:**"
      foreach ($s in $str) { $lines += "- **$(CleanText $s.name)** ($($s.cp)CP, $(CleanText $s.phase))" }
      $lines += ""
    }
  }
  $lines += "## Units"
  $lines += ""
  $lines += "| Photo | Unit | Role | Points |"
  $lines += "|---|---|---|---|"
  foreach ($u in @($fdata.units)) {
    $img = $imgMap.$fid.($u.id)
    $cell = ""
    if ($img) {
      $url = if ($img -like 'gw:*') { $GW + $img.Substring(3) } else { $RAW + ($img -replace ' ', '%20') }
      $cell = "![photo\|60]($url)"
    }
    $pts = if (@($u.costs).Count) { @($u.costs)[0].cost } else { "" }
    $lines += "| $cell | $(CleanText $u.name) | $(CleanText $u.role) | $pts |"
  }
  $safeName = $meta.name -replace $illegalFsChars, ''
  $facNotes += $safeName
  WriteNote "40 Army Intelligence\Factions\$safeName.md" $lines
}
$idx = @("---", "tags: [faction, moc]", "---", "# Factions — Index", "",
  "One note per faction, generated from the same data the app runs on.", "")
$idx += ($facNotes | Sort-Object | ForEach-Object { "- [[$_]]" })
WriteNote "40 Army Intelligence\40 Factions Index.md" $idx

Write-Host "Done. Vault: $vault"
