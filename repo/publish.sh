#!/bin/bash
# Build the signed yum repo for GitHub Pages in site/ and push it.
#   REPO_URL=https://<owner>.github.io/<repo> repo/publish.sh out-rpms extras
#
# extras/ holds EPEL runtime libs our build needs that old servers may lack (oniguruma 6.8.2,
# libonig.so.5: IUS php72u < 7.2.31-2 used EPEL's older libonig.so.2).
#
# Adds the binary RPMs (no debuginfo) from each <rpm-dir> to x86_64/ and any .src.rpm to SRPMS/,
# signs them, regenerates and signs both repodata trees, and writes site/setup.sh with the public
# key embedded. Generates the signing key on first run. Pushes site/ if it has a git remote
# (set NO_PUSH=1 to build and test first).
#
# The private key lives in signing/gnupg. Never commit it; back it up somewhere safe.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=localhost/php72u-el7-build
SITE=$TOP/site
GNUPG=$TOP/signing/gnupg
REPO_ID=${REPO_ID:-el7-repo}
REPO_URL=${REPO_URL:?set REPO_URL, e.g. https://<owner>.github.io/<repo>}
KEY_NAME="$REPO_ID signing key"
KEY_FILE=RPM-GPG-KEY-$REPO_ID

mkdir -p "$SITE/x86_64/Packages" "$SITE/SRPMS" "$GNUPG"
chmod 700 "$TOP/signing" "$GNUPG"
touch "$SITE/.nojekyll"

for d in "$@"; do
  # never overwrite a published package: same NEVR must keep the same bytes/checksum
  cp -pn $(ls "$d"/*.rpm | grep -v -e '\.src\.rpm$' -e debuginfo) "$SITE/x86_64/Packages/"
  # publish source RPMs too, so the build is auditable and rebuildable
  srpms=$(ls "$d"/*.src.rpm 2>/dev/null || true)
  [ -z "$srpms" ] || cp -pn $srpms "$SITE/SRPMS/"
done

podman run --rm --userns=keep-id \
  -v "$SITE:/site:Z" -v "$GNUPG:/gnupg:Z" \
  -e GNUPGHOME=/gnupg -e KEY_NAME="$KEY_NAME" -e KEY_FILE="$KEY_FILE" \
  "$IMAGE" bash -euo pipefail -c '
    if ! gpg2 --list-secret-keys "$KEY_NAME" >/dev/null 2>&1; then
      echo "generating signing key: $KEY_NAME"
      gpg2 --batch --gen-key <<EOF
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: $KEY_NAME
Expire-Date: 0
%commit
EOF
    fi
    gpg2 --armor --export "$KEY_NAME" > /site/$KEY_FILE
    gpg2 --with-colons --fingerprint "$KEY_NAME" | awk -F: "/^fpr/{print \$10; exit}" > /site/.fpr

    # sign only packages not already signed by us (re-signing changes their bytes)
    keyid=$(tail -c 9 /site/.fpr | tr A-F a-f)
    unsigned=$(for f in /site/x86_64/Packages/*.rpm /site/SRPMS/*.rpm; do
                 [ -e "$f" ] || continue
                 rpm -qp --qf "%{SIGPGP:pgpsig}" "$f" 2>/dev/null | grep -qi "$keyid" || echo "$f"
               done)
    # rpm 4.11 always asks for a passphrase; the key has none, so feed it an empty line
    [ -z "$unsigned" ] || echo | rpm --define "_gpg_name $KEY_NAME" --addsign $unsigned >/dev/null

    for arch in x86_64 SRPMS; do
      createrepo -q $( [ -d /site/$arch/repodata ] && echo --update ) /site/$arch
      gpg2 --batch --yes --armor --detach-sign -u "$KEY_NAME" /site/$arch/repodata/repomd.xml
    done
  '

FPR=$(cat "$SITE/.fpr"); rm -f "$SITE/.fpr"
sed -e "s|@REPO_ID@|$REPO_ID|g" -e "s|@REPO_URL@|$REPO_URL|g" -e "s|@KEY_FPR@|$FPR|g" \
    "$TOP/repo/setup.sh.in" \
  | awk -v k="$SITE/$KEY_FILE" '/^@KEY@$/{while ((getline l < k) > 0) print l; next} {print}' \
  > "$SITE/setup.sh"
cp "$TOP/repo/check-php2shell.sh" "$SITE/check-php2shell.sh"
cp "$TOP/repo/update.sh" "$SITE/update.sh"
cp "$TOP/repo/EVIDENCE.md" "$SITE/EVIDENCE.md"

echo "repo built in $SITE (key $FPR)"

if [ -z "${NO_PUSH:-}" ] && git -C "$SITE" remote get-url origin >/dev/null 2>&1; then
  git -C "$SITE" add -A
  git -C "$SITE" commit -qm "Update repo $(date -u +%Y-%m-%dT%H:%MZ)" || true
  git -C "$SITE" push -q origin HEAD
  echo "pushed to $(git -C "$SITE" remote get-url origin)"
fi
