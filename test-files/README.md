# Synthetic recovery kit

Select any archive or PDF here, choose **My wordlist**, and select `wordlist-2000.txt`. Turn **Try common variations** off for a quick, reproducible check.

The list contains exactly 2,000 entries. Each of the 11 files has a different password, between lines 981 and 1021. `manifest.json` records the password, exact line, format, PDF revision and SHA-256 for every file. All contents are synthetic and contain no private data.

Coverage: traditional ZIP, AES-256 ZIP, 7z with encrypted headers/data, RAR3, RAR5, and PDF revisions 2–6. PDF R6 uses the CPU; revisions 2–5 have Metal filters. Metal filters require CPU verification before a recovery is accepted.

The ordinary words are the first 2,000 distinct entries from the bundled Openwall `password.lst`, with 11 replaced by the synthetic passwords. Its source header identifies the list as assumed public domain. `benchmark-vectors.json` contains hashes extracted from these synthetic files; the app bundles a matching copy for its optional benchmark.

## Regenerate or verify

From the repository root, run `scripts/create-demo-fixtures.py` with Python 3 and `pypdf[crypto]` available. It accepts `--sevenzip`, `--rar`, `--runtime` and `--destination`; tools remain local. Existing files are verified and preserved. Generated encryption salts are random, so new destinations have different archive hashes.

RAR3 generation requires RAR 6.x. The local generation run used the official macOS ARM RAR 6.24 trial archive at [RARLAB](https://www.rarlab.com/rar/rarmacos-arm-624.tar.gz), SHA-256 `dabe335834fb5f0fc236f03ba0d12c19fad7243cc56b980db61201ff94d84795`. RAR is separately licensed and is not included in this kit or in the app. ZIP and 7z were generated with local 7-Zip 26.03; PDF files with pypdf 6.10.0.
