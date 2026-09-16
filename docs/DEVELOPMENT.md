# Build and release

The distributable is **Apple Silicon / macOS 13+**. Execution on the minimum OS and additional Macs still needs qualification; setting the deployment target is not a hardware test. Intel releases are not provided.

## Local build

Install Xcode or Apple Command Line Tools and accept their terms yourself. Required build tools: Apple SDK, Swift, Clang, make, Python 3 and Perl.

```sh
scripts/build-runtime.sh --source github --jobs 4
scripts/build-app.sh
swift test
```

Use `--source original` to fetch upstream archives. Both sources must match [the pinned checksums](../dependencies/manifest.json). Cached source archives remain in `dependencies/cache/`; temporary compilation trees are removed. The app is written to `dist/ZipRipper.app`. Ordinary local builds use an ad-hoc signature.

```sh
python3 scripts/prepare-test-fixtures.py
ZIPRIPPER_INTEGRATION_ROOT="$PWD" swift test
```

GPU/integration tests require a compatible local Mac and the bundled runtime. CI skips unavailable hardware/integration cases rather than claiming them as passing. [Synthetic fixtures](../test-files/) are also available for manual testing.

## Signed distribution

The **Signed release** workflow runs explicitly from `main`. It builds the pinned runtime and app, creates an ephemeral signing keychain, notarizes/staples the app, packages the approved BinaryBears DMG, then notarizes/staples it and checks Gatekeeper. Selecting **publish** creates the versioned GitHub release only after these checks pass. Failed signing never falls back to unsigned distribution.

Required GitHub secret names:

- `APPLE_CERTIFICATE_P12_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`
- `APPLE_API_KEY_BASE64`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`

Configure values privately. Never commit certificates, keys, environment files or keychains. The workflow always restores/removes temporary signing state and uploads only the named DMG, checksums and sanitized verification report.

Packaging uses [the BinaryBears layout](../packaging/dmg/config/layout.json), preserved brand artwork and a headless `.DS_Store` writer. Install packaging dependencies in a virtual environment from `packaging/requirements.txt`. Finder/DMG inspection remains a release check.

## Update checklist

1. Update the app version in the bundle script, app fallbacks, release scripts/workflow and public documentation.
2. Review upstream changes; pin and verify replacement source archives before updating the manually maintained BB Github Mirror.
3. Run tests, real CPU/Metal recoveries, pause/resume and benchmark checks; inspect the app at both sizes and the mounted DMG.
4. Refresh the concise manual/screenshots. Run `python3 scripts/audit-public.py`; inspect staged files and public history.
5. Run the release workflow. Verify the actual public DMG checksum, Apple ticket and unauthenticated download.

GitHub Pages deploys only `site/` from `main`. The site is static, has no analytics, and uses relative asset paths for the repository URL.
