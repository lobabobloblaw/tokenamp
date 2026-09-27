# Packaging and releases

| File | Purpose |
|---|---|
| `../VERSION` | The app version (`MAJOR.MINOR.PATCH`). `scripts/build_app.sh` writes it into `CFBundleShortVersionString` and `CFBundleVersion`. |
| `../scripts/package_release.sh` | Builds the universal app, signs/notarizes it when configured, and writes `dist/Tokenamp-<version>.zip` plus `.sha256`. |
| `../.github/workflows/release.yml` | On a pushed `v*` tag: runs the three test suites, packages, and publishes the GitHub Release. |
| `Tokenamp.entitlements` | Entitlements for the hardened-runtime signature. Empty on purpose; the file explains why. |
| `homebrew/tokenamp.rb` | Cask template for the tap `lobabobloblaw/homebrew-tap`. |
| `homebrew/update_cask.sh` | Fills the cask's `version` and `sha256` from a published release. |
| `release-notes/v<version>.md` | Optional hand-written notes for a tag (the directory does not exist until the first one is written). |

## Cut a release

1. Set the new version in `VERSION` and commit it.
2. Optional: write `packaging/release-notes/v<version>.md`. Leave out download, checksum and
   first-launch text; the workflow appends those. Without the file, GitHub's generated changelog is
   used instead.
3. Tag and push: `git tag v<version> && git push origin v<version>`. A tag `v<version>-<suffix>`
   (for example `v0.2.0-rc.1`) publishes a pre-release. The workflow refuses a tag that does not
   match `VERSION`.

To try the packaging locally first: `scripts/package_release.sh` (add `--no-universal` for a
host-only build). It unpacks its own zip and runs the app's `--selftest` from it before writing
the checksum.

The zip is universal (arm64 + x86_64). The Intel slice is cross-compiled with
`swift build --triple x86_64-apple-macosx13.0` and joined with `lipo`; it can be run (and its
selftest checked) only where Rosetta is installed, which CI installs.

## Update the Homebrew tap

One-time: create the public repository `lobabobloblaw/homebrew-tap` with a `Casks/` directory.
Users then install with `brew install --cask lobabobloblaw/tap/tokenamp`.

After each release is published:

```sh
packaging/homebrew/update_cask.sh --out ../homebrew-tap/Casks/tokenamp.rb   # downloads the zip, checks it, hashes it
cd ../homebrew-tap && git commit -am "tokenamp <version>" && git push
```

Always hash the published asset (the default), not a local build: CI builds its own zip and two
builds never have identical bytes.

## Signing and notarization

Today releases are ad-hoc signed and not notarized, so users have to allow the first launch (see
the README). An ad-hoc signature is tied to the exact build, so macOS treats every update as a new
app: the approval, and Homebrew's "signer changed" notice, come back with each release.

`package_release.sh` switches on signing and notarization from environment variables:

| Variable | Effect |
|---|---|
| `TOKENAMP_SIGN_IDENTITY` | `Developer ID Application: Name (TEAMID)` or its SHA-1: sign with the hardened runtime, a secure timestamp and `Tokenamp.entitlements`. `-` rehearses the same configuration with an ad-hoc identity (useful now; cannot be notarized). |
| `TOKENAMP_NOTARY_PROFILE` | A `notarytool` keychain profile: submit, wait, staple, and check with `spctl`. |
| `TOKENAMP_SIGN_KEYCHAIN`, `TOKENAMP_NOTARY_KEYCHAIN` | Optional keychain files holding the identity and the profile. |
| `TOKENAMP_REQUIRE_NOTARIZATION=1` | Fail instead of producing an unnotarized zip. |

`notarytool` and `stapler` ship with the Command Line Tools; Xcode is not needed.

When the Developer ID arrives:

1. In the Apple Developer account, create a **Developer ID Application** certificate and install it
   in the login keychain. Create an app-specific password for the Apple ID at account.apple.com.
2. Locally, store the notary credentials once and package:

   ```sh
   xcrun notarytool store-credentials tokenamp-notary --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
   TOKENAMP_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
   TOKENAMP_NOTARY_PROFILE=tokenamp-notary scripts/package_release.sh
   ```

3. For CI, export the certificate with its private key from Keychain Access as a `.p12`, then add
   these repository secrets (Settings > Secrets and variables > Actions):

   | Secret | Value |
   |---|---|
   | `MACOS_CERTIFICATE_P12_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy` |
   | `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
   | `APPLE_ID` | the developer Apple ID |
   | `APPLE_TEAM_ID` | the 10-character Team ID |
   | `APPLE_APP_SPECIFIC_PASSWORD` | the app-specific password |

   The workflow needs no edits. With the certificate secrets alone it signs; with all five it also
   notarizes and fails rather than publish an unnotarized build.
4. Remove the quarantine caveat from `homebrew/tokenamp.rb` and the first-launch note from the
   README. The release body drops its first-launch block by itself once a build is notarized.

Signing does not change what the app can do: it is not sandboxed, reads the Claude Code keychain
item through `/usr/bin/security`, and needs no entitlements (details in `Tokenamp.entitlements`).
