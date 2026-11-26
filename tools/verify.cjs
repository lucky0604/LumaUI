const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const toc = fs.readFileSync(path.join(root, 'LumaUI.toc'), 'utf8');
const files = toc.split(/\r?\n/).map(s => s.trim()).filter(s => s && !s.startsWith('#'));
let errors = 0;
function check(condition, message) { if (!condition) { console.error(message); errors++; } }
check(toc.includes('## SavedVariables: LumaUIDB'), 'SavedVariables must be declared');
check(!toc.includes('16001'), 'Manifest must target Retail only');
check(fs.readFileSync(path.join(root,'.gitignore'),'utf8').split(/\r?\n/).includes('/agent_flow/'), 'Local workflow directory must be ignored');
const seen = new Set();
for (const entry of files) {
  const normalized = entry.replaceAll('\\','/');
  check(!normalized.includes('..') && !path.isAbsolute(normalized), `Unsafe manifest entry: ${entry}`);
  check(!seen.has(normalized), `Duplicate manifest entry: ${entry}`);
  seen.add(normalized);
  check(fs.existsSync(path.join(root, normalized)), `Missing manifest entry: ${entry}`);
}
let parser;
try { parser = require(process.env.LUMA_LUAPARSE || 'luaparse'); } catch { /* Optional external syntax parser. */ }
// Without the Lua 5.1 grammar module, fall back to an installed Lua 5.1
// compatible parser. LuaJIT is the same grammar; a 5.4/5.5 interpreter is not,
// so it is never accepted here even if `lua` happens to be first on PATH.
const { spawnSync } = require('node:child_process');
function findLua51() {
  for (const command of ['luajit', 'luac5.1', 'lua5.1']) {
    const probe = spawnSync(command, ['-v'], { encoding: 'utf8' });
    if (probe.error) continue;
    const banner = `${probe.stdout || ''}${probe.stderr || ''}`;
    if (/LuaJIT/i.test(banner) || /Lua 5\.1/.test(banner)) return command;
  }
  return null;
}
const lua51 = parser ? null : findLua51();
function externalParse(file) {
  if (!lua51) return true;
  const args = lua51 === 'luac5.1' ? ['-p', file] : ['-b', file, process.platform === 'win32' ? 'NUL' : '/dev/null'];
  const result = spawnSync(lua51, args, { encoding: 'utf8' });
  if (result.error) return true;
  if (result.status !== 0) {
    check(false, `${file}: ${(result.stderr || result.stdout || 'syntax error').trim()}`);
    return false;
  }
  return true;
}
// Release textures, checked at the byte level: every one is an uncompressed
// 32-bit TGA of the size the Lua theme names, produced by tools/make-media.py
// from neutral values. A texture that silently becomes 24-bit or 8-bit alpha
// loses the soft edges the nine-slice surfaces rely on, and a size mismatch
// stretches every card in the UI.
const MEDIA = [
  ['Media/panel.tga', 128, 128], ['Media/bar.tga', 64, 64], ['Media/rule.tga', 128, 8],
  ['Media/glow.tga', 64, 64], ['Media/inset.tga', 64, 64], ['Media/plate.tga', 32, 32],
  ['Media/shadow.tga', 96, 96],
  ['Media/combat-fill.tga', 64, 16], ['Media/hud-scrim.tga', 128, 32],
];
for (const [rel, width, height] of MEDIA) {
  const file = path.join(root, rel);
  check(fs.existsSync(file), `Missing media: ${rel}`);
  if (!fs.existsSync(file)) continue;
  const b = fs.readFileSync(file);
  check(b.length >= 18, `${rel}: TGA header missing`);
  if (b.length < 18) continue;
  const imageWidth = b.readUInt16LE(12), imageHeight = b.readUInt16LE(14);
  check(b[2] === 2, `${rel}: must be an uncompressed true-colour TGA`);
  check(imageWidth === width && imageHeight === height,
    `${rel}: expected ${width}x${height}, got ${imageWidth}x${imageHeight}`);
  check(b[16] === 32, `${rel}: must be 32-bit`);
  check((b[17] & 0x0f) === 8, `${rel}: must carry an 8-bit alpha channel`);
  // Pillow writes the 26-byte TGA 2.0 footer after the pixel data.
  const payload = 18 + b[0] + imageWidth * imageHeight * 4;
  check(b.length === payload || b.length === payload + 26,
    `${rel}: size does not match an uncompressed 32-bit image`);
}
const forbiddenIndex = process.argv.indexOf('--forbid-name');
const forbidden = forbiddenIndex >= 0 ? process.argv[forbiddenIndex + 1]?.toLowerCase() : null;
let luaCount = 0;
let externallyParsed = 0;
function walk(dir) {
  for (const entry of fs.readdirSync(dir, {withFileTypes:true})) {
    if (['.git','node_modules','dist'].includes(entry.name)) continue;
    if (dir === root && entry.name === 'agent_flow') continue;
    const file = path.join(dir, entry.name);
    if (forbidden) check(!entry.name.toLowerCase().includes(forbidden), `Forbidden filename: ${file}`);
    if (entry.isDirectory()) { walk(file); continue; }
    const source = fs.readFileSync(file, 'utf8');
    if (forbidden) check(!source.toLowerCase().includes(forbidden), `Forbidden content: ${file}`);
    if (entry.name.endsWith('.lua')) {
      luaCount++;
      if (parser) {
        try { parser.parse(source, { luaVersion:'5.1' }); }
        catch (err) { check(false, `${file}: ${err.message}`); }
      } else if (externalParse(file)) {
        externallyParsed++;
      }
      if (!file.includes(`${path.sep}tests${path.sep}`)) check(!/SetScript\s*\(\s*['"]OnUpdate/.test(source), `Idle frame loop: ${file}`);
    }
  }
}
walk(root);
const syntax = parser ? 'Lua 5.1 passed'
  : (lua51 ? `${lua51} (Lua 5.1 compatible) passed on ${externallyParsed} files` : 'not installed (syntax not checked)');
if (errors) process.exitCode = 1;
else console.log(`Manifest: ${files.length} files; Lua: ${luaCount}; syntax parser: ${syntax}; static checks passed.`);
