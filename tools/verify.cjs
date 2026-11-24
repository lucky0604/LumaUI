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
const forbiddenIndex = process.argv.indexOf('--forbid-name');
const forbidden = forbiddenIndex >= 0 ? process.argv[forbiddenIndex + 1]?.toLowerCase() : null;
let luaCount = 0;
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
      }
      if (!file.includes(`${path.sep}tests${path.sep}`)) check(!/SetScript\s*\(\s*['"]OnUpdate/.test(source), `Idle frame loop: ${file}`);
    }
  }
}
walk(root);
if (errors) process.exitCode = 1;
else console.log(`Manifest: ${files.length} files; Lua: ${luaCount}; syntax parser: ${parser ? 'Lua 5.1 passed' : 'not installed (syntax not checked)'}; static checks passed.`);
