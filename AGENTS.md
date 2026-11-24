# LumaUI development

- Target World of Warcraft Retail with Lua 5.1 compatible syntax. Keep the actual tested client build separate from TOC declarations.
- Read `README.md` and the relevant implementation before changing behavior. When local `agent_flow/` records exist, read the review, migration plan and latest iteration; keep new review and planning records there.
- Keep `agent_flow/` ignored and out of release packages. Do not commit or publish local review notes.
- Implement components independently. Do not import code, assets, text, layouts, metadata or naming from a reference UI project.
- Use the LumaUI namespace, lifecycle, theme, capability checks and layout APIs. Optional components must fail independently and release their events and timers.
- Do not perform Lua arithmetic, comparisons, concatenation or persistence with secret values. Use documented native drawing methods where allowed.
- Create and configure protected objects outside combat. A combat queue is not permission to bypass other client restrictions.
- Preserve native UI functionality until the replacement has equivalent behavior and has passed in-game validation, including private auras where relevant.
- Validate changed behavior with focused tests and `node tools/verify.cjs`; use an external Lua 5.1 parser when available. Keep test dependencies outside the released addon.
- Use `tools/package.ps1` (Windows) or `tools/package.sh` (macOS/Linux) to build from the TOC whitelist. Report simulated checks and in-game checks separately; never describe an untested client as verified.
