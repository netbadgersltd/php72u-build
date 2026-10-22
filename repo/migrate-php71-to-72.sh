#!/bin/bash
# Move a CentOS 7 server from IUS php71u to the patched php72u (php2shell fix) in one yum transaction.
# php71u and php72u can't be installed together, so update.sh doesn't apply to a php71u server.
#
#   curl -fsSLO https://netbadgersltd.github.io/el7-repo/migrate-php71-to-72.sh
#   bash migrate-php71-to-72.sh --check-only   # show the plan; change nothing
#   bash migrate-php71-to-72.sh                # backup config, swap php71u -> php72u, restart, verify
#
# Run as root. This is a PHP minor-version upgrade (7.1 -> 7.2), not a patch update: test the site
# on staging first. If any installed php71u package has no php72u equivalent in the repo (pecl
# modules, ioncube, mcrypt ...) the script stops before changing anything.
set -euo pipefail

REPO_URL=${REPO_URL:-https://netbadgersltd.github.io/el7-repo}
REPO_ID=el7-repo
mode=${1:-}

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
case "$mode" in ''|--check-only|--no-evidence) ;; *) echo "usage: migrate-php71-to-72.sh [--check-only | --no-evidence]" >&2; exit 2;; esac
grep -q 'release 7' /etc/redhat-release 2>/dev/null || { echo "CentOS/RHEL 7 only" >&2; exit 1; }

# 1. what is installed?
old=$(rpm -qa --qf '%{NAME}\n' | grep -E '^(mod_)?php71u(-|$)' | sort -u || true)
if [ -z "$old" ]; then
  echo "no php71u packages installed; nothing to migrate" >&2
  rpm -q php72u-common >/dev/null 2>&1 && echo "php72u is installed: use update.sh instead" >&2
  exit 2
fi
if rpm -qa --qf '%{NAME}\n' | grep -qE '^(mod_)?php72u(-|$)'; then
  echo "php71u and php72u packages are both installed; resolve that by hand first:" >&2
  rpm -qa 'php7*u*' | sort >&2; exit 1
fi
echo "== installed php71u packages"; rpm -qa 'php71u*' 'mod_php71u*' | sort

WORK=$(mktemp -d /tmp/php2shell-migrate.XXXXXX); trap 'rm -rf -- "$WORK"' EXIT
get() { curl -fsSL --retry 3 -o "$WORK/$1" "$REPO_URL/$1"; }
get setup.sh
get check-php2shell.sh

# 2. add the repo + signing key (setup.sh verifies the key fingerprint and imports it)
echo; REPO_URL="$REPO_URL" bash "$WORK/setup.sh"; echo

# 3. map every php71u package to its php72u twin and make sure the repo has it
echo "== mapping php71u -> php72u"
new=; missing=
for p in $old; do
  n=${p/php71u/php72u}
  if yum -q --disablerepo='*' --enablerepo="$REPO_ID" list available "$n" >/dev/null 2>&1; then
    new="$new $n"; echo "  $p -> $n"
  else
    missing="$missing $p"; echo "  $p -> (NOT in $REPO_ID)"
  fi
done
if [ -n "$missing" ]; then
  echo >&2
  echo "These installed packages have no php72u equivalent in $REPO_ID:$missing" >&2
  echo "Replace them (php72u builds of pecl modules are in the IUS vault; mcrypt is gone in 7.2) or" >&2
  echo "remove them, then run this again. Nothing has been changed." >&2
  exit 3
fi

if [ "$mode" = --check-only ]; then
  echo; echo "--check-only: plan is clean, no changes made. Run 'bash migrate-php71-to-72.sh' to apply."
  exit 0
fi

# 4. back up config; php71u and php72u use the same paths (/etc/php.ini, /etc/php.d, /etc/php-fpm.d ...)
bk=/root/php71u-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz
tar czf "$bk" --ignore-failed-read /etc/php.ini /etc/php.d /etc/php-zts.d /etc/php-fpm.conf /etc/php-fpm.d \
  /etc/httpd/conf.d/php.conf /etc/httpd/conf.modules.d 2>/dev/null || true
echo "== config backed up to $bk"
rpm -qa 'php71u*' 'mod_php71u*' | sort > "$bk.packages"

# 5. one transaction: remove php71u, install php72u. If it fails yum changes nothing.
echo; echo "== swapping php71u -> php72u"
yum -y --disablerepo='*' --enablerepo="$REPO_ID" swap -- remove $old -- install $new

# 6. restart so workers run the new binaries
if systemctl -q is-active php-fpm 2>/dev/null; then systemctl restart php-fpm; fi
if systemctl -q is-active httpd 2>/dev/null; then
  httpd -t && systemctl restart httpd || echo "WARNING: httpd config test failed or restart failed" >&2
fi
rpm -q php72u-common
php -v | head -1

# config files rpm moved aside or left as .rpmnew need a human look
echo; echo "== config files to review (.rpmsave / .rpmnew)"
find /etc/php* /etc/httpd -name '*.rpmsave' -o -name '*.rpmnew' 2>/dev/null | sort || true

# 7. verify, and write evidence unless asked not to
echo; echo "== verifying"
if [ "$mode" = --no-evidence ]; then
  bash "$WORK/check-php2shell.sh"
else
  host=$(hostname -s 2>/dev/null || hostname)
  out="php2shell-evidence-$host-$(date -u +%Y%m%dT%H%M%SZ).txt"
  bash "$WORK/check-php2shell.sh" --report "$out"
fi
echo
echo "PHP was upgraded 7.1 -> 7.2. Check the application logs for deprecation notices; rollback needs"
echo "the IUS vault (yum swap php72u -> php71u) and the config backup $bk."
