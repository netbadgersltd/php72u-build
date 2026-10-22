# php72u-build (php2shell backport, CentOS 7 / IUS PHP 7.2)

See NOTES.md for the patch/CVE table, test results and decisions. This file is the working context.

## What this is
Patched `php72u-7.2.34-1.el7.ius.sec1` for a client's EOL CentOS 7 fleet (some servers on IUS <=7.2.31-1).
IUS SRPM + 62 `SOURCES/sury-NNNN-*.patch` (Ondrej Sury php7.2 7.2.34-66; spec Patch200-261).
**php2shell fix (CVE-2026-109618/109619) = `SOURCES/sury-0159-Avoid-state-corruption-via-bailout.patch` (Patch261).**
Client pays only if patch status is provable, so verification is behavioural, not changelog-based.

## Locations
- Source repo (public): github.com/netbadgersltd/php72u-build (this dir). `.gitignore` excludes signing/, site/, out-rpms/, extras/, test-*, marketing/, *.log.
- Yum repo (public, GitHub Pages): https://netbadgersltd.github.io/el7-repo/ ; git netbadgersltd/el7-repo checked out in `site/`.
- Signing key "el7-repo signing key" RSA4096, fpr FD83 1955 6B72 F5FE 425E C069 49C9 1831 43F4 7F8A.
  **Private key is `signing/gnupg/`: NEVER commit/publish. Back it up (not yet done).**

## Commands
- Build: `build/build.sh` (podman, CentOS 7 vault root; `--notest` skips %check). Clean test host: `build/Containerfile.client`.
- Publish: `REPO_URL=https://netbadgersltd.github.io/el7-repo repo/publish.sh out-rpms extras` (never overwrites published pkgs; bump Release `.secN` for new builds).
- Server: `curl -fsSLO <repo>/update.sh && bash update.sh` (`--check-only`, `--no-evidence`); proof: `check-php2shell.sh --report FILE` (exit 0 protected, 1 vulnerable, 2 no php72u).

## Decisions / constraints
- Excluded: Debian packaging, 0144 telemetry phone-home, 0117 opcache default, OpenSSL3/ICU/enchant2 compat patches.
- oniguruma 6.8.2 (EPEL, re-signed) shipped in repo for servers on libonig.so.2; user wanted only that dep.
- Do NOT build a working exploit / memory-disclosure PoC for php2shell; differential probes only (user needs no shell).
- Never send user's email to unrelated services. Commits end with `Claude-Session: https://claude.ai/code/session_01DsJXmJY1PnrnsQb1LZXMGX`.

## Open items
- Uncommitted in this repo: `.gitignore` (marketing/), `repo/EVIDENCE.md` (source link). Commit + push to php72u-build.
- Bit-for-bit reproducibility unverified (say "rebuildable from SRPM", not "reproducible").
- LinkedIn post (Option B, " - " not em dashes, client anonymous) + card `marketing/linkedin-php2shell.png`; post should link both Pages and source repo.
- Back up signing key; changelog/commit author email is public.
- Long-running CLI workers aren't restarted by update.sh; systemd restart path untested in container.
- Fleet rollout: only one server reported done.
