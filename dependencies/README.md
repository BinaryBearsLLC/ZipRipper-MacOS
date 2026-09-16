# Bundled runtime

The app contains John Jumbo, private Perl and required native libraries. It runs offline without Homebrew or developer tools. Upstream source archives are unmodified; exact versions, licenses, source URLs and SHA-256 checksums are in [manifest.json](manifest.json).

## Source copies

[BB Github Mirror](https://github.com/BinaryBearsLLC/ZipRipper-MacOS/releases/tag/runtime-sources-2026-09) holds the verified corresponding source archives. BinaryBears updates it manually after testing. The source fetcher supports the original projects or this mirror, verifies cached/downloaded bytes and never silently switches source. Local copies stay in the ignored `dependencies/cache/` directory.

```sh
python3 scripts/fetch-dependencies.py --source github
python3 scripts/fetch-dependencies.py --verify-only
```

## Runtime layout

- `bin/john` locates the adjacent native `run/john`.
- `run/extract-hash` dispatches ZIP, RAR, 7z and PDF extraction.
- `perl/` contains the private interpreter and extractor modules.
- `run/` retains upstream configuration, character sets, rules and `password.lst`.
- `licenses/`, `dependency-manifest.json` and `build-info.json` record provenance.

CPU parallelism uses John's `--fork=N`; OpenMP/OpenCL are disabled. Native Metal kernels are implemented separately in the app. Hashes, pots, wordlists and checkpoints live in writable per-session folders, never in the signed bundle. Upstream extractors are invoked with absolute file paths and a controlled environment.

[Build/release instructions](../docs/DEVELOPMENT.md) · [Complete license overview](../THIRD_PARTY_NOTICES.md)
