#!/bin/bash
# Build original, checksum-pinned sources locally. Never use sudo, Homebrew or CPAN installation.
set -euo pipefail
# A GUI sends signals to this launcher, not to a terminal foreground group.
# Give the worker and all of its make/compiler/download descendants their own
# process group, then cancel that entire group on either termination signal.
if [ "${ZIPRIPPER_BUILD_WORKER:-0}" != 1 ]; then
  set -m
  ZIPRIPPER_BUILD_WORKER=1 /bin/bash "$0" "$@" &
  BUILD_WORKER_PID=$!
  cancel_build() {
    local exit_code="$1"
    trap '' INT TERM
    echo 'Cancelling runtime build and its child processes...' >&2
    kill -TERM -- "-$BUILD_WORKER_PID" 2>/dev/null || true
    wait "$BUILD_WORKER_PID" 2>/dev/null || true
    exit "$exit_code"
  }
  trap 'cancel_build 130' INT
  trap 'cancel_build 143' TERM
  if wait "$BUILD_WORKER_PID"; then exit 0; else exit "$?"; fi
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/dependencies/cache"
MANIFEST="$ROOT/dependencies/manifest.json"
DEST="$ROOT/.local/runtime"
SOURCE=original
MIRROR=
JOBS=4
OFFLINE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cache) CACHE="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --destination) DEST="$2"; shift 2 ;;
    --source) SOURCE="$2"; shift 2 ;;
    --mirror-base-url) MIRROR="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --help) echo 'Usage: build-runtime.sh [--destination DIR] [--cache DIR] [--manifest FILE] [--source original|github] [--mirror-base-url URL] [--jobs N] [--offline]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$JOBS" in ''|*[!0-9]*|0) echo 'Jobs must be a positive integer' >&2; exit 2 ;; esac
if [ "$(uname -s)" != Darwin ] || ! /usr/bin/xcrun --find clang >/dev/null 2>&1; then
  echo 'Rebuilding the runtime requires macOS and Apple Command Line Tools (or Xcode). Install the developer tools yourself, then retry. The packaged app already contains a runtime.' >&2
  exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ]; then
  echo 'Runtime builds require macOS 13 or later.' >&2; exit 1
fi
if ! /usr/bin/xcrun --show-sdk-path >/dev/null 2>&1 || ! /usr/bin/python3 -c 'import ssl, urllib.request' >/dev/null 2>&1 || ! /usr/bin/make --version >/dev/null 2>&1 || ! /usr/bin/perl -e 'exit 0' >/dev/null 2>&1; then
  echo 'Missing Apple SDK, make, Python 3 or Perl. Complete the Apple developer tools installation, then retry.' >&2; exit 1
fi
# Use Apple developer tools only. Avoid accidental dynamic linkage to Homebrew libraries.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export MACOSX_DEPLOYMENT_TARGET=13.0
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH PERL5LIB PERL5OPT PERLLIB
FETCH=(/usr/bin/python3 "$ROOT/scripts/fetch-dependencies.py" --manifest "$MANIFEST" --cache "$CACHE" --source "$SOURCE")
[ -z "$MIRROR" ] || FETCH+=(--mirror-base-url "$MIRROR")
[ "$OFFLINE" -eq 0 ] || FETCH+=(--verify-only)
"${FETCH[@]}"
CACHE="$(cd "$CACHE" && pwd)"
MANIFEST="$(cd "$(dirname "$MANIFEST")" && pwd)/$(basename "$MANIFEST")"
mkdir -p "$(dirname "$DEST")"
DEST="$(cd "$(dirname "$DEST")" && pwd)/$(basename "$DEST")"
if [ -e "$DEST" ]; then
  echo "Destination already exists: $DEST. Choose a new destination; the existing runtime was preserved." >&2
  exit 1
fi
# Upstream makefiles may not tolerate spaces. Stage in a private no-space directory;
# the installed runtime uses relative lookup and is moved only after verification.
BUILD="$(mktemp -d /tmp/zipripper-build.XXXXXXXX)"
STAGE="$BUILD/runtime"
PREFIX="$BUILD/support"
trap 'rm -rf -- "$BUILD"' EXIT

mkdir -p "$STAGE/bin" "$STAGE/run" "$STAGE/licenses" "$PREFIX"
echo "Building in $BUILD (macOS 13 deployment target, $(uname -m), $JOBS compiler jobs)"
extract() {
  local archive
  archive="$(/usr/bin/python3 - "$MANIFEST" "$1" <<'PY'
import json, sys
print(next(d['filename'] for d in json.load(open(sys.argv[1]))['dependencies'] if d['id'] == sys.argv[2]))
PY
)"
  mkdir "$BUILD/$1"
  tar -xf "$CACHE/$archive" -C "$BUILD/$1" --strip-components=1
}
for dependency in john openssl perl xz perl-lzma; do extract "$dependency"; done
case "$(uname -m)" in
  arm64) OPENSSL_TARGET=darwin64-arm64-cc ;;
  x86_64) OPENSSL_TARGET=darwin64-x86_64-cc ;;
  *) echo 'Unsupported architecture' >&2; exit 1 ;;
esac
(
  cd "$BUILD/openssl"
  /usr/bin/perl ./Configure "$OPENSSL_TARGET" no-shared no-tests no-module --prefix="$PREFIX" --libdir=lib -mmacosx-version-min=13.0
  make -j"$JOBS" build_libs
  make install_dev
)
(
  cd "$BUILD/xz"
  CFLAGS='-O2 -mmacosx-version-min=13.0' ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc --disable-nls
  make -j"$JOBS"
  make install
)
(
  cd "$BUILD/perl"
  /bin/sh Configure -des -Dprefix="$STAGE/perl" -Duserelocatableinc -Dcc=clang -Dccflags='-mmacosx-version-min=13.0' -Dldflags='-mmacosx-version-min=13.0' -Dman1dir=none -Dman3dir=none -Uuseshrplib -Duselargefiles
  make -j"$JOBS"
  make install
)
(
  cd "$BUILD/perl-lzma"
  LIBLZMA_INCLUDE="$PREFIX/include" LIBLZMA_LIB="$PREFIX/lib" "$STAGE/perl/bin/perl" Makefile.PL
  make -j"$JOBS"
  make test
  make install
)
(
  cd "$BUILD/john/src"
  CFLAGS='-O2 -mmacosx-version-min=13.0' LDFLAGS="-L$PREFIX/lib -mmacosx-version-min=13.0" CPPFLAGS="-I$PREFIX/include" LIBS="-lcrypto" ./configure --disable-openmp --disable-opencl --disable-pcap --disable-native-tests
  make -j"$JOBS"
)
# Keep configuration, character sets and extractor Perl modules exactly as upstream.
cp "$BUILD/john/run/john" "$STAGE/run/john"
cp "$BUILD/john/run/zip2john" "$STAGE/bin/zip2john"
cp "$BUILD/john/run/rar2john" "$STAGE/bin/rar2john"
cp "$BUILD/john/run/7z2john.pl" "$BUILD/john/run/pdf2john.pl" "$STAGE/run/"
cp -R "$BUILD/john/run/lib" "$STAGE/run/lib"
cp -R "$BUILD/john/run/rules" "$STAGE/run/rules"
for pattern in '*.conf' '*.chr' '*.lst'; do
  find "$BUILD/john/run" -maxdepth 1 -type f -name "$pattern" -exec cp {} "$STAGE/run/" \;
done
# Resolve upstream documentation links so license files remain valid in the bundle.
cp -RL "$BUILD/john/doc" "$STAGE/licenses/john"
cp "$BUILD/openssl/LICENSE.txt" "$STAGE/licenses/OpenSSL-LICENSE.txt"
cp "$BUILD/perl/Artistic" "$STAGE/licenses/Perl-Artistic.txt"
cp "$BUILD/perl/Copying" "$STAGE/licenses/Perl-Copying.txt"
cp "$BUILD/xz/COPYING" "$STAGE/licenses/xz-COPYING.txt"
cp "$BUILD/xz/COPYING.0BSD" "$STAGE/licenses/xz-COPYING.0BSD.txt"
cp "$BUILD/perl-lzma/README" "$STAGE/licenses/Compress-Raw-Lzma-README.txt"
cp "$BUILD/john/src/unrar.h" "$STAGE/licenses/unrar-header.txt"
cp "$MANIFEST" "$STAGE/dependency-manifest.json"
cat > "$STAGE/bin/john" <<'SH'
#!/bin/sh
set -eu
RUNTIME="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
exec "$RUNTIME/run/john" "$@"
SH
cat > "$STAGE/run/extract-hash" <<'SH'
#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then echo 'Usage: extract-hash ARCHIVE' >&2; exit 2; fi
RUNTIME="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# Absolute paths prevent archive names from being interpreted as extractor options.
case "$1" in /*) ARCHIVE="$1" ;; *) ARCHIVE="$PWD/$1" ;; esac
if [ ! -f "$ARCHIVE" ] || [ ! -r "$ARCHIVE" ]; then echo 'Archive is not a readable regular file' >&2; exit 2; fi
unset PERL5OPT PERL5LIB PERLLIB
case "$ARCHIVE" in
  *.[zZ][iI][pP]) exec "$RUNTIME/bin/zip2john" "$ARCHIVE" ;;
  *.[rR][aA][rR]) exec "$RUNTIME/bin/rar2john" "$ARCHIVE" ;;
  *.7[zZ]|*.7[zZ].001) exec "$RUNTIME/perl/bin/perl" "$RUNTIME/run/7z2john.pl" "$ARCHIVE" ;;
  *.[pP][dD][fF]) exec "$RUNTIME/perl/bin/perl" "$RUNTIME/run/pdf2john.pl" -config '' "$ARCHIVE" ;;
  *) echo 'Supported archive extensions: .zip, .rar, .7z, .7z.001, .pdf' >&2; exit 2 ;;
esac
SH
chmod +x "$STAGE/bin/john" "$STAGE/run/extract-hash"
# Reject accidental dependencies on Homebrew, build directories or user libraries.
/usr/bin/python3 - "$STAGE" <<'PY'
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
for path in root.rglob('*'):
    if path.is_symlink() and not path.exists():
        raise SystemExit(f'Broken runtime symlink: {path} -> {path.readlink()}')
    if not path.is_file() or path.is_symlink(): continue
    if 'Mach-O' not in subprocess.check_output(['/usr/bin/file', '-b', str(path)], text=True): continue
    output = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True)
    for line in output.splitlines()[1:]:
        dependency = line.strip().split(' (')[0]
        if not dependency.startswith(('/usr/lib/', '/System/Library/', '@loader_path/', '@rpath/', '@executable_path/')):
            raise SystemExit(f'Non-portable library in {path}: {dependency}')
PY
"$STAGE/bin/john" --test=0 --format=ZIP
"$STAGE/bin/john" --list=build-info
"$STAGE/perl/bin/perl" -MCompress::Raw::Lzma -MDigest::MD5 -MDigest::SHA -MCompress::Zlib -e 'print "Portable extractor modules loaded\n"'
/usr/bin/python3 - "$STAGE" <<'PY'
import json, pathlib, platform, subprocess, sys
root = pathlib.Path(sys.argv[1])
(root / 'build-info.json').write_text(json.dumps({'artifact':'ZipRipper local build from unmodified upstream source archives', 'architecture':platform.machine(), 'deploymentTarget':'13.0', 'buildHost':platform.mac_ver()[0], 'johnBuildInfo':subprocess.check_output([str(root/'bin/john'),'--list=build-info'], text=True)}, indent=2)+'\n')
PY
mv "$STAGE" "$DEST"
"$DEST/perl/bin/perl" -MCompress::Raw::Lzma -e 'print "Relocated Perl module loaded\n"'
echo "Runtime ready: $DEST"
# Downloaded source archives stay in the cache; temporary compilation files are removed.
