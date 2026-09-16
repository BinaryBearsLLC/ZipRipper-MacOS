<p align="center"><img src="assets/Logo_github.png" width="250" alt="BinaryBears"></p>

<h1 align="center">ZipRipper for macOS</h1>
<p align="center">Local password recovery for ZIP, RAR, 7z and PDF.</p>
<p align="center"><a href="https://github.com/BinaryBearsLLC/ZipRipper-MacOS/releases/latest">Download</a> · <a href="https://binarybearsllc.github.io/ZipRipper-MacOS/">Website</a> · <a href="docs/MANUAL.md">User guide</a></p>

<p align="center"><img src="docs/images/home.jpg" width="440" alt="ZipRipper 0.5.3 with its four spherical controls"></p>

## Ready to use

**Apple Silicon · macOS 13+ · v0.5.3**

Download the signed, notarized DMG. Drag **ZipRipper** to **Applications** and open it. The runtime is included: no Homebrew, downloads or developer tools required. Recovery works offline.

- Wordlists, remembered patterns and bounded combination searches.
- Visual Pattern maker, slow example preview, pause/resume and local sessions.
- Multicore CPU and native Metal paths, per-file automatic selection, saved benchmarks and estimated search time.

Use only on files you own or have permission to recover. Recovery is not guaranteed. Archives stay unchanged; recovered passwords are stored in local session files. [Usage and privacy details](docs/MANUAL.md#local-data).

## Under the hood

SwiftUI / AppKit · John the Ripper Jumbo · Metal. Supported GPU paths cover ZIP, 7z, RAR3/5 and PDF R2–R5; unsupported variants and PDF R6 use CPU. GPU survivors receive full CPU verification. [Engine details](docs/MANUAL.md#engine-and-benchmark).

[Build & release](docs/DEVELOPMENT.md) · [Pinned dependencies](dependencies/manifest.json) · [Synthetic test files](test-files/) · [Third-party notices](THIRD_PARTY_NOTICES.md)

Original code: **GPL-3.0-or-later**. [Brand artwork and trademarks](assets/NOTICE.md) are reserved.

## Next

- More hardware and minimum-macOS qualification.
- Broader Metal coverage and measured kernel/batch improvements, including PDF R6.

## Thanks

- **illsk1lls** — the original [ZipRipper](https://github.com/illsk1lls/ZipRipper) project and inspiration.
- **Solar Designer, Openwall and John Jumbo contributors** — [John the Ripper](https://github.com/openwall/john), extractors and test samples.
- The **OpenSSL, Perl, XZ and Compress::Raw::Lzma** maintainers — the portable runtime components.
- **cyclone-github, Daniel Miessler / SecLists, Weakpass and sc0tfree / Mentalist** — the independent wordlist resources linked in the app.

An independent BinaryBears macOS implementation. No affiliation or endorsement by the referenced projects is implied.
