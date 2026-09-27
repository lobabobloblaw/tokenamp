# Contributing to Tokenamp

Thanks for looking at the code. A few things to know before you dive in.

## Read this first

- [`docs/SPEC.md`](docs/SPEC.md) is the contract for everything - what each window shows and why.
  Its amendments at the top override older text.
- [`CLAUDE.md`](CLAUDE.md) has the command list and the architecture in one page.
- Touching a skin? Read [`skins/README.md`](skins/README.md), the artist's manual in
  [`skins/skinkit/README.md`](skins/skinkit/README.md), and the house style in
  [`skins/ART_DIRECTION.md`](skins/ART_DIRECTION.md) before changing any art.

## Toolchain

Command Line Tools only - no Xcode, no XCTest, no xcodebuild. You need:

- Swift, from the Command Line Tools
- Python 3 with `numpy` and `Pillow`, for the skin toolkit

```sh
scripts/build_app.sh    # -> build/Tokenamp.app
```

## Running the tests

There's no XCTest; each suite is compiled into its own binary and runs whole (no per-test filter):

```sh
build/Tokenamp.app/Contents/MacOS/Tokenamp --selftest   # UI / skin engine
swift run usage-dump --selftest                         # data layer
cd skins && python3 -m skinkit.selftest                  # skin toolkit
```

If you touched `skinspec/sprites.json`, also run `python3 scripts/gen_sprites_swift.py --check`.

If you touched a skin, rebuild it and look at the result - rendering is judged by the pixels, not
the code:

```sh
python3 skins/build.py <name>     # writes skins/<name>/preview/*.png
build/Tokenamp.app/Contents/MacOS/Tokenamp --snapshot /tmp/shots --demo --skin skins/dist/<Name>.wsz
```

Skin builds are reproducible - unchanged art gives a byte-identical `.wsz`. CI checks this with
rebuilding every skin and comparing the archives with the committed ones.

`.github/workflows/ci.yml` runs all of the above on every push and pull request.

## Privacy

Tokenamp only reads. It never writes, refreshes, or forwards the Claude Code OAuth token, and from
transcripts it parses only timestamp, message id, model, token counts and the session's project
folder - **never message content**. Keep it that way:

- Don't add code that reads, logs, or stores message text.
- Don't paste your own OAuth token, transcript content, or real project names into an issue, PR, or
  commit. `usage-dump --once --no-live` output is fine to share; the token and your messages are
  not.
- This repo is public - check your diff for secrets, home paths, and personal details before
  pushing.

## Pull requests

Keep them focused, run the relevant selftests, and fill in the PR checklist. For art changes,
include a snapshot or preview image so reviewers can see what changed without building it
themselves.
