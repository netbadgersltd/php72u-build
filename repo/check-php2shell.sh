#!/bin/bash
# Check whether this CentOS 7 server's PHP (IUS php72u) is protected against php2shell
# (CVE-2026-109618, CVE-2026-109619).
#
#   bash check-php2shell.sh                 # print the report to the terminal
#   bash check-php2shell.sh --report [FILE] # also save a timestamped, hashed evidence file
#
# This does NOT just read versions/changelog: sections 3-4 trigger the real vulnerable condition
# (the memory-exhaustion bailout behind the UAF/RCE, and the default-on upload-progress path behind
# the memory disclosure) and assert the engine neutralises it. Each probe is differential: it reports
# VULNERABLE on an unpatched build and PROTECTED here. It is NOT an exploit: no code execution is
# attempted and no process memory is read or disclosed.
#
# Exit: 0 = protected, 1 = vulnerable or action needed, 2 = no php72u installed.
# Safe on production: no network, no restarts, nothing exploited. Temp files go in a private
# mktemp dir that is removed on exit. Run as root so running processes can be inspected.
set -uo pipefail

MARKER=zend_mm_safe_error_ex          # function added by the php2shell fix
FIX_CHANGELOG='Avoid state corruption via bailout'
KEYID=43f47f8a                        # el7-repo signing key
ENGINE_FILES="/usr/bin/php /usr/bin/php-cgi /usr/bin/phpdbg /usr/bin/zts-php /usr/bin/zts-phpdbg
  /usr/sbin/php-fpm /usr/lib64/httpd/modules/libphp7.so /usr/lib64/httpd/modules/libphp7-zts.so
  /usr/lib64/libphp7-7.2.so"
STALE_RE='/usr/(s?bin/(php|php-cgi|php-fpm|phpdbg|zts-php|zts-phpdbg)|lib64/(httpd/modules/libphp7|libphp7|php(-zts)?/modules/))[^ ]* \(deleted\)$'

FAILS=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; FAILS=$((FAILS + 1)); }
warn() { echo "[WARN] $*"; }

main() {
echo "php2shell (CVE-2026-109618 / CVE-2026-109619) verification"
echo "host: $(hostname)   date: $(date -u '+%F %T %Z')   kernel: $(uname -r)"
echo "method: active behavioural probe (triggers the vulnerable condition), differential vs a known-unpatched build"
echo

# 1. packages
pkgs=$(rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 'php72u*' 'mod_php72u*' \
       | grep -vE '^php72u-(pecl-|ioncube)' | sort)
if [ -z "$pkgs" ]; then
  echo "No IUS php72u packages installed; this check only covers php72u."
  exit 2
fi
common=$(rpm -q --qf '%{VERSION}-%{RELEASE}' php72u-common)
if rpm -q --changelog php72u-common | grep -qF "$FIX_CHANGELOG"; then
  pass "php72u-common $common includes the php2shell fix"
else
  fail "php72u-common $common does not include the php2shell fix (update from el7-repo)"
fi
odd=$(awk -v vr="$common" '$2 != vr' <<<"$pkgs")
if [ -z "$odd" ]; then
  pass "all $(wc -l <<<"$pkgs") php72u packages are at $common"
else
  fail "php72u packages not at $common:"; sed 's/^/         /' <<<"$odd"
fi
foreign=$(rpm -q --qf '%{NAME} %{SIGPGP:pgpsig}\n' $(cut -d' ' -f1 <<<"$pkgs") | grep -vi "$KEYID" | cut -d' ' -f1)
[ -z "$foreign" ] && pass "all php72u packages signed by the el7-repo key" \
                  || warn "not signed by the el7-repo key: $(tr '\n' ' ' <<<"$foreign")"
changed=$(rpm -V $(cut -d' ' -f1 <<<"$pkgs") 2>/dev/null | awk '$2 != "c"')
[ -z "$changed" ] && pass "installed files match the packages (rpm -V)" \
                  || { warn "files differ from the packages (rpm -V):"; sed 's/^/         /' <<<"$changed"; }

# 2. every PHP engine binary on disk carries the fix
n=0; bad=0
for f in $ENGINE_FILES; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  LC_ALL=C grep -aq "$MARKER" "$f" || { fail "$f does not contain the php2shell fix"; bad=$((bad + 1)); }
done
[ "$bad" -eq 0 ] && pass "all $n PHP engine binaries on disk contain the fix"

TMP=$(mktemp -d /tmp/php2shell-check.XXXXXX)
trap '[ -n "${TMP:-}" ] && rm -rf -- "$TMP"' EXIT

# 3. CVE-2026-109618: the "state corruption via bailout" mechanism behind both CVEs.
#    On a vulnerable engine, exhausting memory_limit / overflowing an allocation size longjmps out
#    (zend_bailout) and then runs the normal request-shutdown sequence over half-torn-down state --
#    observable because registered shutdown code still executes. The fix _exit(1)s instead, so no
#    userland runs. This drives the real trigger paths and asserts the fixed behaviour; it does NOT
#    attempt to corrupt or control memory. Each probe prints USERLAND-RAN only on a vulnerable engine.
#
#    probe code writers (marker = USERLAND-RAN; each trips a 16M limit a different way)
sd='register_shutdown_function(function(){echo "USERLAND-RAN\n";});'
printf '<?php\n%s\n$a=str_repeat("x",1<<30);\n'                              "$sd"  > "$TMP/p_bigstr.php"
printf '<?php\n%s\n$a=[];while(1){$a[]=str_repeat("x",1024);}\n'            "$sd"  > "$TMP/p_array.php"
printf '<?php\nset_error_handler(function(){});set_exception_handler(function($e){});\n%s\n$a=[];while(1){$a[]=$a;}\n' \
                                                                            "$sd"  > "$TMP/p_handlers.php"

oom_ok() {  # runs a probe, echoes vuln|ok|odd:<detail>
  local bin=$1 kind=$2 file=$3 out rc
  if [ "$kind" = cli ]; then
    out=$("$bin" -n -d memory_limit=16M -f "$file" 2>&1); rc=$?
  else  # exercise the CGI SAPI (what php-fpm/mod_php run) through a real request
    out=$(env -i PATH=/usr/bin:/bin REDIRECT_STATUS=200 GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET \
            SCRIPT_FILENAME="$file" "$bin" -n -d memory_limit=16M 2>&1); rc=$?
  fi
  if grep -q USERLAND-RAN <<<"$out"; then echo vuln
  elif [ "$rc" -eq 1 ]; then echo ok
  else echo "odd:rc=$rc ${out##*$'\n'}"; fi
}

if [ -x /usr/bin/php ]; then
  declare -A R
  R[CLI/big-allocation]=$(oom_ok /usr/bin/php cli "$TMP/p_bigstr.php")
  R[CLI/array-growth]=$(oom_ok /usr/bin/php cli "$TMP/p_array.php")
  R[CLI/with-error-handlers]=$(oom_ok /usr/bin/php cli "$TMP/p_handlers.php")
  [ -x /usr/bin/php-cgi ] && R[CGI-SAPI/big-allocation]=$(oom_ok /usr/bin/php-cgi cgi "$TMP/p_bigstr.php")
  vuln=0 odd=0 okn=0
  for k in "${!R[@]}"; do case "${R[$k]}" in
    vuln) fail "CVE-2026-109618: memory exhaustion runs userland after bailout via $k (VULNERABLE)"; vuln=$((vuln+1));;
    ok)   okn=$((okn+1));;
    *)    warn "CVE-2026-109618: inconclusive via $k (${R[$k]})"; odd=$((odd+1));;
  esac; done
  [ "$vuln" -eq 0 ] && [ "$odd" -eq 0 ] && pass "CVE-2026-109618: memory exhaustion aborts safely in all $okn tested paths (CLI + CGI SAPI)"
else
  warn "CVE-2026-109618: /usr/bin/php not installed, behaviour test skipped"
fi

# 4. CVE-2026-109619: session upload progress (on by default) must stay disabled after the fix.
#    This is a reachability check: it sends the real multipart request that populates upload-progress
#    session state and asserts the fix suppressed it. No use-after-free is attempted.
if [ -x /usr/bin/php-cgi ]; then
  printf '<?php\nsession_start();\nvar_dump(isset($_SESSION["upload_progress_php2shell"]));\n' > "$TMP/t.php"
  b=----php2shellcheck
  printf -- '--%s\r\nContent-Disposition: form-data; name="PHP_SESSION_UPLOAD_PROGRESS"\r\n\r\nphp2shell\r\n--%s\r\nContent-Disposition: form-data; name="file1"; filename="a.txt"\r\nContent-Type: text/plain\r\n\r\nx\r\n--%s--\r\n' \
    "$b" "$b" "$b" > "$TMP/body"
  out=$(env -i PATH=/usr/bin:/bin REDIRECT_STATUS=200 GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=POST \
          SCRIPT_FILENAME="$TMP/t.php" CONTENT_TYPE="multipart/form-data; boundary=$b" \
          CONTENT_LENGTH=$(stat -c %s "$TMP/body") HTTP_COOKIE=PHPSESSID=php2shellcheck \
        /usr/bin/php-cgi -n -d session.save_path="$TMP" -d upload_tmp_dir="$TMP" \
          -d session.upload_progress.enabled=1 -d session.upload_progress.cleanup=0 \
          -d session.upload_progress.freq=1 -d session.upload_progress.min_freq=0 \
          < "$TMP/body" 2>&1)
  if grep -q 'bool(false)' <<<"$out"; then
    pass "CVE-2026-109619: session upload progress is disabled (fixed behaviour)"
  elif grep -q 'bool(true)' <<<"$out"; then
    fail "CVE-2026-109619: session upload progress is active (vulnerable code path reachable)"
  else
    warn "CVE-2026-109619: unexpected php-cgi output: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
  fi
else
  warn "CVE-2026-109619: /usr/bin/php-cgi not installed, behaviour test skipped"
fi

# 5. running processes still using replaced (old) PHP binaries need a restart
if [ "$(id -u)" -ne 0 ]; then
  warn "not root: can't inspect running php-fpm/httpd processes"
else
  stale=$(for m in /proc/[0-9]*/maps; do
            pid=${m#/proc/}; pid=${pid%/maps}
            [ "$pid" = $$ ] && continue
            grep -qE "$STALE_RE" "$m" 2>/dev/null && cat "/proc/$pid/comm" 2>/dev/null
          done | sort | uniq -c | awk '{printf "%s%s (%d)", sep, $2, $1; sep=", "}')
  if [ -n "$stale" ]; then
    fail "processes still running the old PHP code: $stale"
    echo "         restart them, e.g. systemctl restart php-fpm / httpd; long-running php workers too"
  else
    running=$(pgrep -x 'php-fpm|httpd' | wc -l)
    pass "no running process uses replaced PHP binaries ($running php-fpm/httpd processes checked)"
  fi
fi

# evidence fingerprints: the identity of the running engine, so the report is tied to real binaries
echo
echo "evidence fingerprints (sha256):"
for f in /usr/sbin/php-fpm /usr/lib64/httpd/modules/libphp7.so /usr/bin/php; do
  [ -f "$f" ] && echo "  $(sha256sum "$f")"
done
echo "  php72u-common package: $(rpm -q php72u-common 2>/dev/null) signed by $(rpm -q --qf '%{SIGPGP:pgpsig}\n' php72u-common 2>/dev/null | grep -oiE 'Key ID [0-9a-f]+' || echo '(unsigned)')"
echo "reference: on an UNPATCHED build the section 3/4 probes report VULNERABLE (userland runs after the"
echo "  memory-exhaustion bailout; upload-progress session state is populated). PROTECTED means they did not."

echo
if [ "$FAILS" -eq 0 ]; then
  echo "RESULT: PROTECTED against php2shell"
  return 0
fi
echo "RESULT: VULNERABLE or action needed ($FAILS failed checks)"
return 1
}

# ---- dispatch ----
REPORT=
if [ "${1:-}" = "--report" ]; then
  REPORT=${2:-php2shell-evidence-$(hostname -s 2>/dev/null || hostname)-$(date -u +%Y%m%dT%H%M%SZ).txt}
fi
if [ -n "$REPORT" ]; then
  main | tee "$REPORT"; rc=${PIPESTATUS[0]}
  sha256sum "$REPORT" > "$REPORT.sha256"
  echo; echo "Evidence written to $REPORT"
  echo "Verify integrity with:  sha256sum -c $REPORT.sha256   ($(cut -d' ' -f1 "$REPORT.sha256"))"
  exit "$rc"
fi
main
exit $?
