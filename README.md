# php72u-build — php2shell security backport for CentOS 7 / IUS PHP 7.2

Source and build recipe for the patched `php72u` packages that fix **php2shell**
(CVE-2026-109618, CVE-2026-109619) and other security bugs on end-of-life CentOS 7
with PHP 7.2 from the (also EOL) IUS repository.

This repo is the auditable *source*. The signed binary RPMs, the matching SRPM, and the
install/verify scripts are distributed from the companion repo:

**→ https://github.com/netbadgersltd/el7-repo** (served at https://netbadgersltd.github.io/el7-repo/)

## What this produces

`php72u-7.2.34-1.el7.ius.sec1`, a drop-in update over IUS's last build (`7.2.34-1.el7.ius`, 2020).
It takes IUS's final SRPM and applies 62 security patches backported from Ondřej Surý's actively
maintained `php7.2` packaging (cross-checked against Remi Collet's and AlmaLinux's fixes). The full
patch-to-CVE table, what was deliberately left out, and the behaviour changes are in [NOTES.md](NOTES.md).

## Reproduce the build

Requires `podman` and `rpmbuild` on the host. The build runs in a pinned CentOS 7 container
(vault + EPEL archive mirrors), so it does not depend on the host distribution.

```
build/build.sh            # build SRPM + RPMs and run the upstream test suite (%check)
build/build.sh --notest   # skip %check (faster)
```

Output lands in `out/`. The spec is `SPECS/php72u.spec` (`SPECS/php72u.spec.orig` is the untouched
IUS original for diffing); the backported patches are `SOURCES/sury-*.patch`.

Anyone can instead rebuild straight from the published SRPM:

```
rpm -i https://netbadgersltd.github.io/el7-repo/SRPMS/php72u-7.2.34-1.el7.ius.sec1.src.rpm
rpmbuild -ba ~/rpmbuild/SPECS/php72u.spec --define 'dist .el7.ius'
```

## Layout

- `SPECS/` — the spec and the original IUS spec
- `SOURCES/` — upstream tarball, IUS sources, and the `sury-*` security patches
- `build/` — `Containerfile` (build root), `Containerfile.client` (a clean EL7 test host),
  `build.sh`, `verify.sh`
- `repo/` — distribution tooling: `publish.sh` (build the signed yum repo), `setup.sh.in`,
  `update.sh`, `check-php2shell.sh`, and [repo/EVIDENCE.md](repo/EVIDENCE.md) (how patch status is proven)
- `NOTES.md` — decisions, patch/CVE table, test results, ABI notes

## Not in this repo

The GPG signing key (private) is never committed. `extras/` (EPEL's `oniguruma-6.8.2`, needed only
when publishing for servers still on `libonig.so.2`) and build outputs are excluded; see NOTES.md.
