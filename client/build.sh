#!/bin/sh
# Builds ServerGuardianClient.zip, the BeamMP client mod, with scripts/ and lua/ at the root of the zip.
# Usage: ./build.sh [output.zip]     (default: ServerGuardianClient.zip next to this script)
# Uses zip when it is installed, otherwise python3's zipfile. Nothing else is needed.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out=${1:-"$here/ServerGuardianClient.zip"}
case $out in
  /*) ;;
  *) out="$PWD/$out" ;;
esac

rm -f "$out"
cd "$here"

if command -v zip >/dev/null 2>&1; then
  zip -X -D -q -r "$out" scripts lua -x '*.DS_Store'
elif command -v python3 >/dev/null 2>&1; then
  python3 -I - "$out" scripts lua <<'PY'
import os
import sys
import zipfile

out, roots = sys.argv[1], sys.argv[2:]
names = []
for root in roots:
    for folder, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(files):
            if not name.startswith("."):
                names.append(os.path.join(folder, name).replace(os.sep, "/"))
names.sort()
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
    for name in names:
        info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        with open(name, "rb") as handle:
            archive.writestr(info, handle.read())
PY
else
  echo "build.sh needs either zip or python3" >&2
  exit 1
fi

echo "built $out"
