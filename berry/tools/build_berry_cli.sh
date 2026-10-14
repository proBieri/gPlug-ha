#!/bin/bash
# Builds (once, then cached) a local "berry" command-line compiler from
# exactly the Berry source Tasmota uses for the ESP32 firmware
# (lib/libesp32/berry in the Tasmota repo, at the exact tag set below).
#
# Why an exact tag instead of e.g. the generic berry-lang/berry project:
# Tasmota patches/extends Berry (among other things, for int64 emulation on
# the 32-bit ESP32). Only the tag matching the firmware version guarantees a
# bytecode format compatible with the gPlug. See TASMOTA_TAG below - when the
# gPlug firmware is updated, this tag must be updated along with it, or the
# resulting .bec could be incompatible.
#
# Output: path to the built "berry" binary on stdout (last line).
set -e
cd "$(dirname "$0")"

TASMOTA_TAG="${TASMOTA_TAG:-v15.3.0}"
CACHE_DIR="$PWD/.cache/tasmota-$TASMOTA_TAG"
BERRY_BIN="$CACHE_DIR/berry"

if [ -x "$BERRY_BIN" ]; then
  echo "$BERRY_BIN"
  exit 0
fi

echo "Building berry CLI for Tasmota $TASMOTA_TAG (once, cached under .cache/)..." >&2

# Fetched as a tarball instead of "git clone" (no git command needed - the CI
# image has none installed). GitHub names the tag tarball's root directory
# "<repo>-<tag without leading 'v'>" (verified here: v15.3.0 ->
# "Tasmota-15.3.0").
SRC_DIR="$CACHE_DIR/src"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
ARCHIVE_ROOT="Tasmota-${TASMOTA_TAG#v}"
(
  cd "$SRC_DIR"
  curl -sL --fail "https://github.com/arendst/Tasmota/archive/refs/tags/$TASMOTA_TAG.tar.gz" |
    tar -xz \
      "$ARCHIVE_ROOT/lib/libesp32/berry" \
      "$ARCHIVE_ROOT/lib/libesp32/re1.5" \
      "$ARCHIVE_ROOT/lib/libesp32/berry_mapping" \
      "$ARCHIVE_ROOT/lib/libesp32/berry_int64" \
      "$ARCHIVE_ROOT/lib/libesp32/berry_custom"
) >&2

(cd "$SRC_DIR/$ARCHIVE_ROOT/lib/libesp32/berry" && make -j4) >&2

cp "$SRC_DIR/$ARCHIVE_ROOT/lib/libesp32/berry/berry" "$BERRY_BIN"
rm -rf "$SRC_DIR"

echo "berry CLI built: $BERRY_BIN" >&2
echo "$BERRY_BIN"
