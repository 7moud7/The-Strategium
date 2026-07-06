// Build a self-contained test artifact of The Strategium:
// - React + ReactDOM inlined
// - JSX precompiled (no Babel at runtime)
// - Data subset embedded + fetch() shim (artifact CSP blocks all hosts)
const fs = require('fs');
const path = require('path');
const Babel = require('./babel-standalone-7.23.2-pkg/babel.min.js');

const APP = '/home/user/The-Strategium/App/thestrategium.html';
const REPO = '/home/user/The-Strategium';
const src = fs.readFileSync(APP, 'utf8');

// 1. style block
const style = src.match(/<style>([\s\S]*?)<\/style>/)[1];

// 2. app script (text/babel)
const appScript = src.match(/<script type="text\/babel">([\s\S]*?)<\/script>/)[1];

console.log('compiling JSX…', appScript.length, 'chars');
const compiled = Babel.transform(appScript, { presets: ['react'] }).code;
console.log('compiled:', compiled.length, 'chars');

// 3. libs
const react = fs.readFileSync('./react-18.2.0-pkg/umd/react.production.min.js', 'utf8');
const reactDom = fs.readFileSync('./react-dom-18.2.0-pkg/umd/react-dom.production.min.js', 'utf8');

// 4. embedded data — keys are DECODED url suffixes
const embed = {};
const add = (key, file) => { embed[key] = JSON.parse(fs.readFileSync(file, 'utf8')); };

// 40k: trimmed index + four factions
const fullIndex = JSON.parse(fs.readFileSync(path.join(REPO, 'WH40K/Data/Unit Data/index.json'), 'utf8'));
const KEEP = ['ORK', 'TAU', 'NEC', 'TYR'];
const trimmedIndex = {};
KEEP.forEach(k => { if (fullIndex[k]) trimmedIndex[k] = fullIndex[k]; });
embed['Unit Data/index.json'] = trimmedIndex;
add('Unit Data/ork.json', path.join(REPO, 'WH40K/Data/Unit Data/ork.json'));
add('Unit Data/tau.json', path.join(REPO, 'WH40K/Data/Unit Data/tau.json'));
add('Unit Data/nec.json', path.join(REPO, 'WH40K/Data/Unit Data/nec.json'));
add('Unit Data/tyr.json', path.join(REPO, 'WH40K/Data/Unit Data/tyr.json'));
// army rules for those factions
add('WH40K/Data/Orks.json', path.join(REPO, 'WH40K/Data/Orks.json'));
add('WH40K/Data/Tau_Empire.json', path.join(REPO, 'WH40K/Data/Tau_Empire.json'));
add('WH40K/Data/Necrons.json', path.join(REPO, 'WH40K/Data/Necrons.json'));
add('WH40K/Data/Tyranids.json', path.join(REPO, 'WH40K/Data/Tyranids.json'));
// rules + box sizes
add('Rules/core-rules.json', path.join(REPO, 'WH40K/Rules/core-rules.json'));
add('Data/box-sizes.json', path.join(REPO, 'WH40K/Data/box-sizes.json'));
// AoS: everything
const aosDir = path.join(REPO, 'AoS/Data');
for (const f of fs.readdirSync(aosDir)) {
  add('AoS/Data/' + f, path.join(aosDir, f));
}

const shim = `
// ── TEST-BUILD FETCH SHIM ────────────────────────────────────────────────
// This artifact runs under a strict CSP (no network). Embedded data below
// serves the app; anything not embedded fails gracefully like being offline.
const __EMBED=${JSON.stringify(embed)};
const __EMBED_KEYS=Object.keys(__EMBED).sort((a,b)=>b.length-a.length);
const __origFetch=window.fetch.bind(window);
window.fetch=function(url,opts){
  let u=String(url&&url.url||url);
  try{u=decodeURIComponent(u);}catch(e){}
  const key=__EMBED_KEYS.find(k=>u.endsWith(k));
  if(key){
    return Promise.resolve(new Response(JSON.stringify(__EMBED[key]),{status:200,headers:{'Content-Type':'application/json'}}));
  }
  return __origFetch(url,opts).catch(e=>{ throw e; });
};
`;

const banner = `
<div style="position:fixed;bottom:0;left:0;right:0;z-index:9999;background:#1a1408;border-top:1px solid #6b5a2a;color:#c8a84b;font:9px/1.6 monospace;letter-spacing:1px;text-align:center;padding:3px 8px;pointer-events:none;">
TEST BUILD · offline data: Orks / T'au / Necrons / Tyranids + all AoS factions · images, videos &amp; Commander AI disabled by sandbox
</div>`;

const out = `<title>THE STRATEGIUM — Test Build</title>
<style>${style}</style>
<div id="root"></div>
${banner}
<script>${react}</script>
<script>${reactDom}</script>
<script>${shim}</script>
<script>${compiled}</script>
`;

fs.writeFileSync('strategium-test.html', out);
console.log('artifact size:', (out.length / 1048576).toFixed(2), 'MB ->', 'strategium-test.html');
