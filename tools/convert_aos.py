#!/usr/bin/env python3
"""Convert BSData age-of-sigmar-4th catalogues into The Strategium's AoS JSON.

Output layout (mirrors the WH40K Unit Data approach):
  AoS/Data/index.json                 {factionId: {name, file, units}}
  AoS/Data/<slug>.json                {id, name, source, battleTraits, units: [...]}

Unit shape:
  {id, name, move, health, save, control, ward, points, unitSize, notReinforceable,
   keywords: [], weapons: [{name,type,rng,atk,hit,wnd,rnd,dmg,ability}],
   abilities: [{name, type, timing, declare, effect, keywords}]}
"""
import xml.etree.ElementTree as ET
import json, os, re, sys, unicodedata

SRC = 'aoscat'
OUT = '/home/user/The-Strategium/AoS/Data'
FACTIONS = ['Stormcast Eternals','Cities of Sigmar','Blades of Khorne','Disciples of Tzeentch',
 'Maggotkin of Nurgle','Hedonites of Slaanesh','Slaves to Darkness','Skaven','Soulblight Gravelords',
 'Nighthaunt','Ossiarch Bonereapers','Flesh-eater Courts','Ironjawz','Kruleboyz','Gloomspite Gitz',
 'Sons of Behemat','Ogor Mawtribes','Sylvaneth','Daughters of Khaine','Idoneth Deepkin',
 'Lumineth Realm-lords','Fyreslayers','Kharadron Overlords','Seraphon','Beasts of Chaos','Bonesplitterz']

def slug(name):
    s = unicodedata.normalize('NFKD', name).encode('ascii','ignore').decode()
    return re.sub(r'[^a-z0-9]+','-',s.lower()).strip('-')

def txt(el):
    return re.sub(r'\s+',' ',''.join(el.itertext())).strip() if el is not None else ''

def parse_faction(name):
    B = None
    def tag(t): return f'{B}{t}'

    lib_path = os.path.join(SRC, f'{name} - Library.cat')
    cat_path = os.path.join(SRC, f'{name}.cat')
    lib = ET.parse(lib_path).getroot()
    cat = ET.parse(cat_path).getroot()
    B = '{%s}' % lib.tag.split('}')[0][1:]

    # Points from the faction cat entry links (cost name="pts"), keyed by targetId
    points = {}
    for el in cat.iter(tag('entryLink')):
        for c in el.iter(tag('cost')):
            if c.attrib.get('name') == 'pts':
                try: points[el.attrib.get('targetId')] = int(float(c.attrib.get('value','0')))
                except ValueError: pass

    # Battle traits (faction abilities) from the faction cat
    traits = []
    for se in cat.iter(tag('selectionEntry')):
        if 'Battle Traits' in (se.attrib.get('name') or ''):
            for p in se.iter(tag('profile')):
                if (p.attrib.get('typeName') or '').startswith('Ability'):
                    chars = {c.attrib.get('name'): txt(c) for c in p.iter(tag('characteristic'))}
                    traits.append({
                        'name': p.attrib.get('name'),
                        'type': p.attrib.get('typeName'),
                        'declare': chars.get('Declare',''),
                        'effect': chars.get('Effect',''),
                        'keywords': chars.get('Keywords',''),
                    })
            break

    units = []
    for se in lib.iter(tag('selectionEntry')):
        if se.attrib.get('type') != 'unit':
            continue
        uid = se.attrib.get('id')
        uname = se.attrib.get('name')
        unit = {'id': uid, 'name': uname, 'move':'', 'health':'', 'save':'', 'control':'',
                'ward':'', 'points': points.get(uid), 'unitSize': 0, 'keywords': [],
                'weapons': [], 'abilities': []}

        # keywords (direct categoryLinks only, to avoid picking up children's)
        cl_parent = se.find(tag('categoryLinks'))
        if cl_parent is not None:
            unit['keywords'] = [c.attrib.get('name') for c in cl_parent.findall(tag('categoryLink'))]

        for p in se.iter(tag('profile')):
            tn = p.attrib.get('typeName') or ''
            chars = {c.attrib.get('name'): txt(c) for c in p.iter(tag('characteristic'))}
            if tn in ('Unit','Manifestation','Faction Terrain'):
                unit['move'] = chars.get('Move','')
                unit['health'] = chars.get('Health','')
                unit['save'] = chars.get('Save','')
                unit['control'] = chars.get('Control', chars.get('Banishment',''))
            elif tn in ('Melee Weapon','Ranged Weapon'):
                unit['weapons'].append({
                    'name': p.attrib.get('name'),
                    'type': 'Melee' if tn=='Melee Weapon' else 'Ranged',
                    'rng': chars.get('Rng',''),
                    'atk': chars.get('Atk',''),
                    'hit': chars.get('Hit',''),
                    'wnd': chars.get('Wnd',''),
                    'rnd': chars.get('Rnd',''),
                    'dmg': chars.get('Dmg',''),
                    'ability': chars.get('Ability',''),
                })
            elif tn.startswith('Ability'):
                unit['abilities'].append({
                    'name': p.attrib.get('name'),
                    'type': tn,
                    'timing': chars.get('Timing',''),
                    'declare': chars.get('Declare',''),
                    'effect': chars.get('Effect',''),
                    'keywords': chars.get('Keywords',''),
                })

        # Ward from keywords like "WARD (5+)" or an ability named "Ward (5+)"
        for kw in unit['keywords']:
            m = re.match(r'WARD \((\d\+)\)', kw or '')
            if m: unit['ward'] = m.group(1)
        if not unit['ward']:
            for ab in unit['abilities']:
                m = re.match(r'Ward \((\d\+)\)', ab['name'] or '')
                if m: unit['ward'] = m.group(1)

        # unit size = sum of each model child's DIRECT min constraint
        # (iter() would sweep grandchildren's constraints and pick wrong values)
        size = 0
        for ch in se.iter(tag('selectionEntry')):
            if ch.attrib.get('type') == 'model' and ch is not se:
                cwrap = ch.find(tag('constraints'))
                if cwrap is None: continue
                for k in cwrap.findall(tag('constraint')):
                    if k.attrib.get('type') == 'min':
                        try: size += int(float(k.attrib.get('value','0')))
                        except ValueError: pass
                        break
        unit['unitSize'] = size or 1

        # de-dup weapons (same profile can appear under multiple model entries)
        seen = set(); wl=[]
        for w in unit['weapons']:
            key = (w['name'], w['type'], w['atk'], w['dmg'])
            if key in seen: continue
            seen.add(key); wl.append(w)
        unit['weapons'] = wl
        # de-dup abilities
        seen = set(); al=[]
        for a in unit['abilities']:
            if a['name'] in seen: continue
            seen.add(a['name']); al.append(a)
        unit['abilities'] = al

        units.append(unit)

    # de-dup units by name (linked duplicates), keep the one with points
    byname = {}
    for u in units:
        cur = byname.get(u['name'])
        if cur is None or (u['points'] and not cur['points']):
            byname[u['name']] = u
    units = sorted(byname.values(), key=lambda u: u['name'])

    return {'id': slug(name), 'name': name, 'source': 'BSData/age-of-sigmar-4th',
            'battleTraits': traits, 'units': units}

def main():
    os.makedirs(OUT, exist_ok=True)
    index = {}
    for name in FACTIONS:
        f = parse_faction(name)
        fn = f['id'] + '.json'
        with open(os.path.join(OUT, fn), 'w') as fh:
            json.dump(f, fh, separators=(',',':'))
        withpts = sum(1 for u in f['units'] if u['points'])
        index[f['id']] = {'name': name, 'file': fn, 'units': len(f['units'])}
        print(f"{name:28s} units={len(f['units']):3d} with-points={withpts:3d} traits={len(f['battleTraits'])}")
    with open(os.path.join(OUT, 'index.json'), 'w') as fh:
        json.dump(index, fh, indent=1)
    print('OK ->', OUT)

if __name__ == '__main__':
    main()
