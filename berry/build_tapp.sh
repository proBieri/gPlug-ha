#!/bin/bash
# Builds gplug_ha.tapp - a Tasmota Application from gplug_ha.be.
#
# A .tapp is an UNCOMPRESSED zip (store mode, hence zip -0 -X): Tasmota scans
# the filesystem for *.tapp at boot and automatically runs the autoexec.be
# contained within it. Advantage over single files: only one upload, and any
# autoexec.be already present on the device stays untouched.
#
# gplug_ha.be and gplug_ha_setup.be are precompiled to bytecode (.bec) before
# they're packed into the .tapp - the gPlug then loads ready-made bytecode
# instead of compiling the source itself on every boot, which saves the heap
# the on-device compiler would need and shortens startup. The readable source
# is this repository. The "berry" compiler needed for this is
# built by tools/build_berry_cli.sh from the Tasmota Berry source matching
# the exact gPlug firmware (once, then cached).
#
# gplug_ha_setup.be is the one-time script.txt parser gplug_ha.be hands off
# to (see gplug_ha.be's run_setup_and_restart()) on first install or whenever
# script.txt changes - kept in a SEPARATE .bec so its OBIS/CSV parsing layer
# never has to sit resident in memory on a normal boot. Both .bec files ship
# in the same .tapp; only gplug_ha.bec is loaded directly by autoexec.be.
#
# Usage:  ./build_tapp.sh        -> produces gplug_ha.tapp in this directory
set -e
cd "$(dirname "$0")"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

BERRY_BIN=$(./tools/build_berry_cli.sh)

# Strip comments from the shipped files (more compact .tapp) - quote-aware,
# so '#' inside Berry strings isn't mistaken for the start of a comment.
python3 "$(dirname "$0")/strip_comments.py" gplug_ha.be > "$STAGE/gplug_ha.be"
python3 "$(dirname "$0")/strip_comments.py" gplug_ha_setup.be > "$STAGE/gplug_ha_setup.be"

# -g (named globals) when precompiling: without this flag, the .bec stores an
# index-based snapshot of the globals known at compile time. For classes that
# Tasmota only registers LAZILY as a native class on first access (e.g.
# tcpclient/webclient - not used in this app's v1, but relevant for future
# extensions), that would block the lazy creation at runtime and silently
# leave the class as nil (verified elsewhere on real gPlug hardware). -g
# instead forces name-based resolution without a snapshot.
(cd "$STAGE" && "$BERRY_BIN" -g "$OLDPWD/tools/compile_to_bec.be" gplug_ha.be gplug_ha.bec)
(cd "$STAGE" && "$BERRY_BIN" -g "$OLDPWD/tools/compile_to_bec.be" gplug_ha_setup.be gplug_ha_setup.bec)

cat > "$STAGE/autoexec.be" <<'EOF'
load(tasmota.wd + "gplug_ha.bec")
EOF

rm -f gplug_ha.tapp
(cd "$STAGE" && zip -0 -X -q "$OLDPWD/gplug_ha.tapp" autoexec.be gplug_ha.bec gplug_ha_setup.bec)

echo "gplug_ha.tapp built:"
unzip -v gplug_ha.tapp
