// Builds the deployable site from the hand-maintained single-file app.
//
// The app is authored as one HTML file with a big <script type="text/babel">
// block. Compiling that in the browser cost ~3s of blocked main thread (far
// worse on phones) plus a 2.8MB babel-standalone download on every visit, so
// the JSX is compiled here instead and the transformer is dropped.
//
// Source is read from the repo when present (Vercel's git builds), and pulled
// from GitHub otherwise so a standalone deploy still gets the latest push.
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import * as babel from '@babel/core';

const SRC = 'App/thestrategium.html';
const RAW = 'https://raw.githubusercontent.com/7moud7/The-Strategium/main/App/thestrategium.html';

const src = existsSync(SRC)
  ? readFileSync(SRC, 'utf8')
  : await fetch(RAW, { cache: 'no-cache' }).then((r) => {
      if (!r.ok) throw new Error(`fetching ${RAW} failed: HTTP ${r.status}`);
      return r.text();
    });

const block = src.match(/<script type="text\/babel">([\s\S]*?)<\/script>/);
if (!block) throw new Error('no <script type="text/babel"> block in source');

const { code } = babel.transformSync(block[1], {
  presets: [['@babel/preset-react', { runtime: 'classic' }]],
  compact: false,
  babelrc: false,
  configFile: false,
});

const out = src
  .replace(/\s*<script src="[^"]*babel-standalone[^"]*"><\/script>/, '')
  .replace(block[0], '<script>\n' + code + '\n</script>');

if (/babel-standalone|type="text\/babel"/.test(out)) {
  throw new Error('build left a runtime-babel reference behind');
}

mkdirSync('dist', { recursive: true });
writeFileSync('dist/index.html', out);
console.log(`built dist/index.html — ${Math.round(out.length / 1024)}KB (from ${existsSync(SRC) ? 'repo' : 'GitHub'})`);
