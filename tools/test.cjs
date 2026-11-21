const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const root = path.resolve(__dirname,'..');
const files = fs.readFileSync(path.join(root,'LumaUI.toc'),'utf8').split(/\r?\n/)
  .filter(s=>s.trim().endsWith('.lua')).map(s=>s.trim().replaceAll('\\','/'));
// Generate the manifest table from the real TOC even on Lua hosts without io.lines.
const bootstrap = `LUMA_TEST_FILES = {${files.map(s=>JSON.stringify(s)).join(',')}}`;
const executable = process.env.LUMA_LUA || 'lua';
const args = process.env.LUMA_LUA_JS
  ? [process.env.LUMA_LUA_JS,'-e',bootstrap,'tests/run.lua']
  : ['-e',bootstrap,'tests/run.lua'];
const result = spawnSync(process.env.LUMA_LUA_JS ? process.execPath : executable, args, {cwd:root,stdio:'inherit'});
if (result.error) { console.error(result.error.message); process.exitCode = 1; }
else process.exitCode = result.status ?? 1;
