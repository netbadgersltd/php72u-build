#!/bin/bash
# Repoint a CentOS 7 server's dead yum repos at working archives.
#
#   curl -fsSLO https://netbadgersltd.github.io/el7-repo/centos7-repo-cleanup.sh
#   bash centos7-repo-cleanup.sh --dry-run    # show what would change; change nothing
#   bash centos7-repo-cleanup.sh              # fix repos; ask before disabling unknown dead ones
#   bash centos7-repo-cleanup.sh -y           # same, but disable unknown dead repos without asking
#
# For every ENABLED repo in /etc/yum.repos.d/*.repo:
#   - if it already works (repodata/repomd.xml downloads), it is left alone
#   - else if it is a known repo (CentOS base/updates/extras/centosplus/fasttrack/cr, SCLo, EPEL, IUS)
#     its baseurl is replaced with a working archive and the old mirrorlist/baseurl line is
#     kept as a "#cleanup#" comment
#   - else you are asked whether to disable it (default yes)
# Originals are copied to /root/yum.repos.d-backup-<timestamp>/. Our el7-repo is never touched.
set -euo pipefail

REPOD=/etc/yum.repos.d
RELVER=7
ARCH=$(uname -m)
TIMEOUT=20
dry=0; yes=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1;;
    -y|--yes) yes=1;;
    *) echo "usage: centos7-repo-cleanup.sh [--dry-run] [-y]" >&2; exit 2;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
grep -q 'release 7' /etc/redhat-release 2>/dev/null || { echo "CentOS/RHEL 7 only" >&2; exit 1; }
[ "$ARCH" = x86_64 ] || { echo "only x86_64 is mapped" >&2; exit 1; }

NSC=http://mirror.nsc.liu.se/centos-store/centos/$RELVER
SCLO=http://vault.centos.org/7.9.2009/sclo/$ARCH
EPEL=https://archives.fedoraproject.org/pub/archive/epel/$RELVER/$ARCH
IUS=https://vault.ius.io/el$RELVER/$ARCH

# known-good replacement baseurl for a repo id (empty = unknown)
known_url() {
  case "$1" in
    base|C7*-base)               echo "$NSC/os/$ARCH/";;
    updates|C7*-updates)         echo "$NSC/updates/$ARCH/";;
    extras|C7*-extras)           echo "$NSC/extras/$ARCH/";;
    centosplus|C7*-centosplus)   echo "$NSC/centosplus/$ARCH/";;
    fasttrack|C7*-fasttrack)     echo "$NSC/fasttrack/$ARCH/";;
    cr)                          echo "$NSC/cr/$ARCH/";;
    centos-sclo-rh|sclo-rh)      echo "$SCLO/rh/";;
    centos-sclo-sclo|sclo-sclo)  echo "$SCLO/sclo/";;
    epel)                        echo "$EPEL/";;
    ius|ius-archive)             echo "$IUS/";;
    *) ;;
  esac
}

# does a repo URL serve repodata?
works() { curl -fsSL -o /dev/null -m "$TIMEOUT" "${1%/}/repodata/repomd.xml" 2>/dev/null; }

subst() { sed -e "s/\$releasever/$RELVER/g" -e "s/\$basearch/$ARCH/g" -e 's/\$infra/stock/g' -e "s/\$contentdir/centos/g"; }

# does the repo's current config work? (first baseurl, or first entry of mirrorlist/metalink)
current_works() {
  local base=$1 ml=$2 first
  if [ -n "$base" ]; then works "$(echo "$base" | subst)"; return; fi
  if [ -n "$ml" ]; then
    first=$(curl -fsSL -m "$TIMEOUT" "$(echo "$ml" | subst)" 2>/dev/null | grep -m1 -E '^https?://' || true)
    [ -n "$first" ] && works "$first"; return
  fi
  return 1
}

ask_disable() {
  [ "$yes" = 1 ] && return 0
  { : </dev/tty; } 2>/dev/null || { echo "    (no terminal: disabling)"; return 0; }
  local ans=; read -r -p "    no known working source for '$1'. Disable it? [Y/n] " ans </dev/tty || true
  case "$ans" in n|N|no|NO) return 1;; *) return 0;; esac
}

# list enabled repos as: file|id|baseurl|mirrorlist|metalink
list_repos() {
  awk -v F="$1" '
    function flush() { if (id != "" && en != 0) print F "|" id "|" bu "|" ml "|" mt }
    /^\[.*\]/ { flush(); id=$0; gsub(/[][]/, "", id); en=1; bu=""; ml=""; mt=""; next }
    /^[ \t]*enabled[ \t]*=/ { v=$0; sub(/^[^=]*=[ \t]*/, "", v); en=(v+0); next }
    /^[ \t]*baseurl[ \t]*=/ && bu=="" { bu=$0; sub(/^[^=]*=[ \t]*/, "", bu); next }
    /^[ \t]*mirrorlist[ \t]*=/ { ml=$0; sub(/^[^=]*=[ \t]*/, "", ml); next }
    /^[ \t]*metalink[ \t]*=/ { mt=$0; sub(/^[^=]*=[ \t]*/, "", mt); next }
    END { flush() }' "$1"
}

ACTIONS=$(mktemp); trap 'rm -f -- "$ACTIONS"' EXIT   # lines: file|id|set|url  or  file|id|disable
echo "== checking enabled repos in $REPOD"
for f in "$REPOD"/*.repo; do
  [ -e "$f" ] || continue
  while IFS='|' read -r file id bu ml mt; do
    case "$id" in el7-repo) echo "  [skip] $id (ours)"; continue;; esac
    cur=$bu; mlk=${ml:-$mt}
    if current_works "$cur" "$mlk"; then echo "  [ok]   $id"; continue; fi
    url=$(known_url "$id")
    if [ -n "$url" ] && works "$url"; then
      echo "  [fix]  $id -> $url"; echo "$file|$id|set|$url" >> "$ACTIONS"
    else
      echo "  [dead] $id (${cur:-$mlk})"
      if ask_disable "$id"; then echo "  [off]  $id"; echo "$file|$id|disable" >> "$ACTIONS"
      else echo "  [keep] $id left as is"; fi
    fi
  done < <(list_repos "$f")
done

if [ ! -s "$ACTIONS" ]; then echo; echo "nothing to change"; exit 0; fi
if [ "$dry" = 1 ]; then echo; echo "--dry-run: no changes made"; exit 0; fi

bk=/root/yum.repos.d-backup-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$bk"; cp -p "$REPOD"/*.repo "$bk"/
echo; echo "== originals saved in $bk"

for f in $(cut -d'|' -f1 "$ACTIONS" | sort -u); do
  out=$(mktemp)
  awk -F'|' -v F="$f" '
    FNR==NR { if ($1 == F) { act[$2]=$3; url[$2]=$4 } next }
    function flush() { if (cur != "" && act[cur] == "disable" && !seen) print "enabled=0" }
    /^\[.*\]/ { flush(); cur=$0; gsub(/[][]/, "", cur); seen=0; print
                if (act[cur] == "set") print "baseurl=" url[cur]; next }
    cur != "" && act[cur] != "" && /^[ \t]*(baseurl|mirrorlist|metalink)[ \t]*=/ { print "#cleanup# " $0; next }
    cur != "" && act[cur] == "disable" && /^[ \t]*enabled[ \t]*=/ { print "enabled=0"; seen=1; next }
    { print }
    END { flush() }' "$ACTIONS" "$f" > "$out"
  cat "$out" > "$f"; rm -f "$out"
done

echo "== cleaning yum metadata and testing"
yum clean all >/dev/null 2>&1 || true
if yum -q makecache fast >/dev/null 2>&1 || yum -q makecache >/dev/null 2>&1; then
  echo "yum makecache OK"
else
  echo "WARNING: yum makecache still fails; originals are in $bk" >&2; exit 1
fi
