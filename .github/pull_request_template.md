<!-- Thanks for the PR! A short description of what changed and why goes well here. -->

## Checklist

- [ ] Selftests run and pass: `Tokenamp --selftest`, `swift run usage-dump --selftest`, and (for skin changes) `python3 -m skinkit.selftest`
- [ ] For art changes: looked at the rendered snapshots/previews, not just the code (`--snapshot`, or `skins/<name>/preview/`)
- [ ] `python3 scripts/gen_sprites_swift.py --check` passes (if `skinspec/sprites.json` changed)
- [ ] No secrets, home paths, real session/project names, tokens, or message content in the diff (this repo is public)
