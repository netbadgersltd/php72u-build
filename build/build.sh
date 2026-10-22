#!/bin/bash
# Build the patched php72u SRPM + RPMs in a CentOS 7 container.
#   build/build.sh            full build (runs the test suite in %check)
#   build/build.sh --notest   skip %check
# Env: SPEC (default SPECS/php72u.spec), SOURCES (default SOURCES/), OUT (default out/)
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=localhost/php72u-el7-build
SPEC=${SPEC:-$TOP/SPECS/php72u.spec}
OUT=${OUT:-$TOP/out}
SOURCES=${SOURCES:-$TOP/SOURCES}
CHECK=1
[ "${1:-}" = "--notest" ] && CHECK=0

# BuildRequires are the same for the patched and original spec, so one image serves both
cp "$TOP/SPECS/php72u.spec" "$TOP/build/php72u.spec"
podman build -t "$IMAGE" "$TOP/build"
rm -f "$TOP/build/php72u.spec"

mkdir -p "$OUT"
podman run --rm \
  -v "$SPEC:/src/php72u.spec:ro,Z" \
  -v "$SOURCES:/src/SOURCES:ro,Z" \
  -v "$OUT:/out:Z" \
  --userns=keep-id \
  "$IMAGE" bash -euo pipefail -c "
    mkdir -p ~/rpmbuild/{SPECS,SOURCES}
    cp /src/SOURCES/* ~/rpmbuild/SOURCES/
    cp /src/php72u.spec ~/rpmbuild/SPECS/
    rpmbuild -ba ~/rpmbuild/SPECS/php72u.spec \
      --define 'dist .el7.ius' \
      --define 'runselftest $CHECK' > /out/build.log 2>&1
    cp ~/rpmbuild/SRPMS/*.src.rpm ~/rpmbuild/RPMS/*/*.rpm /out/
    # keep test results for comparison
    find ~/rpmbuild/BUILD -name '*.diff' \\
      | tar -cf /out/test-diffs.tar -T - 2>/dev/null || true
  "
echo "Packages in $OUT"
