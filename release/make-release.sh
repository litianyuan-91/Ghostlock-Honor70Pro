#!/bin/sh
# Assemble the ready-to-use release bundle:
#   release/Honor70Pro-GhostLock-release.tar.gz  (+ .sha256)
#
#   sh release/make-release.sh [cc]     (default cc: aarch64-linux-gnu-gcc)
#
# The archive contains a single top-level directory:
#   Honor70Pro-GhostLock/
#     setup.sh        PC-side driver (POSIX sh)
#     README.txt      usage + hashes
#     payload/
#       exploit_static
#       target.h
set -eu
cd "$(dirname "$0")/.."

TARGET=mtk-SDY-AN00_8.0.0.220
CC="${1:-aarch64-linux-gnu-gcc}"
NAME=Honor70Pro-GhostLock
TGZ="release/$NAME-release.tar.gz"

echo "== building exploit_static (CC=$CC)"
( cd exploit && CC="$CC" make PROJECT="$TARGET" bin >/dev/null )
BIN="exploit/build/$TARGET/bin/exploit_static"
[ -f "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

echo "== staging payload"
mkdir -p release/payload
cp "$BIN" release/payload/exploit_static
cp "exploit/src/targets/$TARGET/target.h" release/payload/target.h
chmod 755 release/payload/exploit_static release/setup.sh

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$NAME/payload"
cp release/setup.sh release/README.txt "$stage/$NAME/"
cp release/payload/exploit_static release/payload/target.h "$stage/$NAME/payload/"
chmod 755 "$stage/$NAME/setup.sh" "$stage/$NAME/payload/exploit_static"

echo "== packaging $TGZ"
tar -C "$stage" -czf "$TGZ" "$NAME"
sha256sum "$TGZ" > "$TGZ.sha256"
echo "built: $TGZ"
cat "$TGZ.sha256"
