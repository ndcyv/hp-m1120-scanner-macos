#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
WORK="$HOME/m1120-sane-test"
PREFIX="$WORK/install"
SOURCE_URL='https://gitlab.com/-/project/429008/uploads/843c156420e211859e974f78f64c3ea3/sane-backends-1.4.0.tar.gz'
SOURCE_SHA='f99205c903dfe2fb8990f0c531232c9a00ec9c2c66ac7cb0ce50b4af9f407a72'
ARCHIVE="$WORK/sane-backends-1.4.0.tar.gz"
print '=== HP M1120: isolated SANE 1.4.0 colour-patch build ==='
if [[ ! -f "$ROOT/patches/m1120-color-buffer.patch" ]]; then
  print 'ERROR: Patch file is missing.' >&2
  exit 1
fi
if ! command -v brew >/dev/null 2>&1; then
  print 'ERROR: Install Homebrew first: https://brew.sh/' >&2
  exit 1
fi
if ! xcrun --find clang >/dev/null 2>&1; then
  print 'ERROR: Apple Command Line Tools are required: xcode-select --install' >&2
  exit 1
fi
for formula in sane-backends pkgconf; do
  if ! brew list --versions "$formula" >/dev/null 2>&1; then
    print "ERROR: Missing Homebrew dependency: $formula" >&2
    exit 1
  fi
done
if [[ -e "$PREFIX" ]]; then
  print "ERROR: $PREFIX already exists; refusing to overwrite an existing scanner installation." >&2
  exit 1
fi
if [[ -e "$WORK/sane-backends-1.4.0" ]]; then
  print "ERROR: Source directory already exists: $WORK/sane-backends-1.4.0" >&2
  exit 1
fi
mkdir -p "$WORK"
if [[ ! -f "$ARCHIVE" ]]; then
  print 'Downloading official SANE 1.4.0 source archive...'
  curl --fail --location --show-error "$SOURCE_URL" -o "$ARCHIVE"
fi
print 'Verifying SHA-256...'
print "$SOURCE_SHA  $ARCHIVE" | shasum -a 256 -c -
tar -xzf "$ARCHIVE" -C "$WORK"
cd "$WORK/sane-backends-1.4.0"
patch --dry-run -p1 < "$ROOT/patches/m1120-color-buffer.patch"
patch -p1 < "$ROOT/patches/m1120-color-buffer.patch"
./configure --prefix="$PREFIX" --without-gphoto2 --with-usb=yes
make -j4
make install
print "Installed patched SANE scanner: $PREFIX/bin/scanimage"
"$PREFIX/bin/scanimage" --version
print 'Keep this install directory; the app requires it.'
