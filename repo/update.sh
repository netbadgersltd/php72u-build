#!/bin/bash
# php2shell one-shot remediation for a CentOS 7 server (IUS php72u).
# Adds the el7-repo, checks for an update, applies it, restarts services, then verifies the server
# is protected and writes a tamper-evident evidence file.
#
#   curl -fsSLO https://netbadgersltd.github.io/el7-repo/update.sh
#   bash update.sh                 # full run: add repo -> update -> restart -> verify -> evidence
#   bash update.sh --check-only    # add repo and report whether an update is available; change nothing
#   bash update.sh --no-evidence   # full run, but don't write the evidence file
#
# Run as root. The verify step triggers the real vulnerable condition (no exploit, no memory read)
# and is differential against a known-unpatched build; see EVIDENCE.md in the repo.
set -euo pipefail

REPO_URL=${REPO_URL:-https://netbadgersltd.github.io/el7-repo}
REPO_ID=el7-repo
mode=${1:-}

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
case "$mode" in ''|--check-only|--no-evidence) ;; *) echo "usage: update.sh [--check-only | --no-evidence]" >&2; exit 2;; esac

WORK=$(mktemp -d /tmp/php2shell-update.XXXXXX); trap 'rm -rf -- "$WORK"' EXIT
get() { curl -fsSL --retry 3 -o "$WORK/$1" "$REPO_URL/$1"; }
get setup.sh
get check-php2shell.sh

# 1. add the repo + signing key (setup.sh verifies the key fingerprint and imports it)
REPO_URL="$REPO_URL" bash "$WORK/setup.sh"
echo

# 2. is an update actually available?
echo "== checking $REPO_ID for php72u updates"
set +e
yum -q --disablerepo='*' --enablerepo="$REPO_ID" check-update 'php72u*' 'mod_php72u*'
avail=$?
set -e
if [ "$avail" -eq 0 ]; then
  echo "php72u is already up to date in $REPO_ID"
elif [ "$avail" -eq 100 ]; then
  echo "an update is available"
else
  echo "check-update failed (rc=$avail)" >&2; exit "$avail"
fi

if [ "$mode" = --check-only ]; then
  echo; echo "--check-only: no changes made. Run 'bash update.sh' to apply and verify."
  [ "$avail" -eq 100 ] && exit 100 || exit 0
fi

# 3. apply the update and restart services (setup.sh --update does both)
echo; echo "== applying update"
REPO_URL="$REPO_URL" bash "$WORK/setup.sh" --update

# 4. verify, and write evidence unless asked not to
echo; echo "== verifying"
if [ "$mode" = --no-evidence ]; then
  bash "$WORK/check-php2shell.sh"
else
  host=$(hostname -s 2>/dev/null || hostname)
  out="php2shell-evidence-$host-$(date -u +%Y%m%dT%H%M%SZ).txt"
  bash "$WORK/check-php2shell.sh" --report "$out"
fi
