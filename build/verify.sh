#!/bin/bash
# Install built RPMs into a clean CentOS 7 container and smoke-test them.
#   build/verify.sh [rpm-dir]     (default: out/)
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
RPMS=$(cd "${1:-$TOP/out}" && pwd)

podman run --rm --user root -v "$RPMS:/rpms:ro,Z" localhost/php72u-el7-build bash -euo pipefail -c '
  cd /rpms
  yum -y -q localinstall $(ls *.rpm | grep -v -e "\.src\.rpm$" -e debuginfo) >/dev/null

  echo "== packages";      rpm -q php72u-common php72u-cli php72u-fpm mod_php72u
  echo "== version";       php -v | head -1
  echo "== modules load";  php -m 2>&1 | grep -iE "warning|error|unable" || echo "no load errors ($(php -m | grep -c .) modules)"
  echo "== max_multipart_body_parts"; php -r "var_dump(ini_get(\"max_multipart_body_parts\"));"

  echo "== php2shell (CVE-2026-109618): OOM must _exit(1) without running shutdown functions"
  set +e
  php -d memory_limit=8M -r "register_shutdown_function(function(){echo \"SHUTDOWN-RAN\n\";});
    \$a = str_repeat(\"x\", 64<<20);" 2>&1
  echo "exit=$?"
  set -e

  echo "== php-fpm -t";    php-fpm -t 2>&1 | grep -v "^$"
  echo "== httpd -t";      httpd -t 2>&1 | tail -1; httpd -M 2>/dev/null | grep -E "php|mpm_"
'
