# php72u 7.2.34 security backport (CentOS 7 / IUS)

Base: IUS `php72u-7.2.34-1.el7.ius` (last IUS build, Oct 2020, from vault.ius.io).
Fixes: Ondřej Surý's `php7.2 7.2.34-66` (ppa:ondrej/php, Oct 2026), cross-checked
against Remi Collet's `php-7.2.34-29.remi` (Aug 2026).

Result: `php72u-7.2.34-1.el7.ius.sec1`. It upgrades over `-1.el7.ius` with plain `yum`/`rpm -U`.

## php2shell (CVE-2026-109618, CVE-2026-109619): covered by Patch261 (sury-0159)

Unauthenticated RCE in the engine, CVSS 9.2, exploited in the wild since Oct 21 2026. Upstream fixed
only 8.2+; for 7.x there's a "minimal mitigation" (php-src 712e60f9, 7.4 branch) by Arnaud Le Blanc.

- -109618: hitting memory_limit mid-request (a crafted multipart upload) bails out while request state
  is half-initialized, and cleanup reads the corrupted state.
- -109619: after a fatal error, global state (user error/exception handlers, object store) isn't reset
  before request memory is freed, so the next request on the same worker hits a UAF. Reachable via
  per-dir INI warnings (`.htaccess`, `PHP_VALUE`) and session upload progress (on by default).
- Most exposed: mod_php + prefork (both CVEs confirmed exploitable), then FPM (-109619 confirmed).

sury-0159 is Le Blanc's own 7.2 backport of that commit. Checked against AlmaLinux 8's independent 7.2
backport (`php-7.2.24-1...alma.1`, `php-cve-2026-109618-109619.patch`): same files, same state resets.
The differences are only where 7.2.24 lacked things we already have (`max_multipart_body_parts`,
`ZSTR_MAX_LEN`) and where the singleton-array helper lives. Ours resets the stale handlers before the
object store is freed, not after, which is the slightly tighter ordering and matches the 7.4 commit.

**Deliberate behavior changes (same as upstream 7.4 and AlmaLinux):**
- memory_limit exhaustion and allocation-size overflow print `Fatal error: ...` to **stderr** and the
  worker `_exit(1)`s: no bailout, no shutdown functions, no session write, no error_log entry.
  FPM: 502 for that request, and the master logs `child N exited with code 1` in
  `/var/log/php-fpm/error.log`. With IUS's default `catch_workers_output` off, the message itself goes
  nowhere, and `www-error.log` stops showing "Allowed memory size exhausted". mod_php: the httpd child
  exits and the message lands in httpd's error_log.
- Session upload progress is hard-disabled (`|| 1`), regardless of `session.upload_progress.enabled`.

**Interim mitigation until the package is rolled out** (from the AlmaLinux advisory):
`session.upload_progress.enabled = 0` in `/etc/php.d/` (not `ini_set`/`.user.ini`); remove per-dir
settings that raise warnings; lower `post_max_size` (8M, or 32M if uploads are needed); for mod_php,
move to event MPM + php-fpm. These reduce exposure; they don't fix the bug.

**Check a box is patched** (`php -v` says 7.2.34 either way):
```
rpm -q php72u-common          # want 7.2.34-1.el7.ius.sec1
php -d memory_limit=8M -r 'register_shutdown_function(function(){echo "SHUTDOWN-RAN\n";});
  $a = str_repeat("x", 64<<20);'; echo "exit=$?"
# unpatched: prints SHUTDOWN-RAN, exit=255    patched: no SHUTDOWN-RAN, exit=1
```

## Layout

- `SPECS/php72u.spec`: patched spec (`php72u.spec.orig` is the IUS original)
- `SOURCES/`: IUS sources + `sury-NNNN-*.patch` (NNNN = Ondřej's series number)
- `build/`: CentOS 7 container build root (vault + EPEL archive) and `build.sh`
- `out-rpms/`: **the deliverable**: SRPM + 35 binary RPMs + debuginfo, `SHA256SUMS`
- `test-patched/`, `test-baseline/`: full `make test` build logs, patched vs unmodified IUS
- `build/verify.sh <rpm-dir>`: installs RPMs in a clean EL7 container and smoke-tests them

```
build/build.sh             # patched build, runs the test suite
build/build.sh --notest    # skip %check
```

## Yum repo (GitHub Pages)

Public, signed repo at https://netbadgersltd.github.io/el7-repo/ (git: `netbadgersltd/el7-repo`,
checked out in `site/`). Key `el7-repo signing key`, RSA 4096, fingerprint
`FD83 1955 6B72 F5FE 425E C069 49C9 1831 43F4 7F8A`, generated with EL7's gpg so rpm 4.11 can verify it.

- **Private key: `signing/gnupg/`** (no passphrase, not in any git repo). Back it up somewhere safe.
  If it's lost you can't publish updates the servers will accept without re-running setup.sh everywhere.
- Server, once: `curl -fsSLO https://netbadgersltd.github.io/el7-repo/setup.sh && bash setup.sh --update`
- Server, later: `yum -y --disablerepo='*' --enablerepo=el7-repo update 'php72u*' 'mod_php72u*'`
  (`--disablerepo='*'` so dead CentOS 7/IUS mirrors don't block it; our RPMs need nothing new).
  php-fpm restarts itself on upgrade. For mod_php, `systemctl restart httpd` (setup.sh does this).
- Publish new builds: `REPO_URL=https://netbadgersltd.github.io/el7-repo repo/publish.sh out-rpms`
  signs, regenerates and signs repodata, rewrites setup.sh, commits and pushes `site/`.
  Bump `Release` (`.sec2`, ...) so yum sees an update.

Tested in a CentOS 7 container with the original IUS 7.2.34-1 packages installed: setup + update
runs without prompts, all 12 packages go to `.sec1`, `rpm -K` passes, a second run is a no-op, and a
tampered `repomd.xml` is rejected (`signature could not be verified`).

**oniguruma:** IUS php72u up to 7.2.31-1 linked EPEL's oniguruma 5.9.5 (`libonig.so.2`). EPEL moved to
6.8.2 (`libonig.so.5`) in May 2020, and IUS rebuilt as 7.2.31-2. Servers still on the old build failed
the update (`Requires: libonig.so.5()(64bit)`), so `extras/oniguruma-6.8.2-2.el7` (EPEL binary,
re-signed with our key) ships in el7-repo and comes in as a dependency. If something else on a
server still needs `libonig.so.2` (e.g. an old EPEL `jq`), yum refuses the update and changes nothing.
Tested on a clean client image (`build/Containerfile.client`) with IUS 7.2.31-1 + oniguruma 5.9.5.

**check-php2shell.sh** (`repo/`, also published at the repo root): `curl -fsSLO
https://netbadgersltd.github.io/el7-repo/check-php2shell.sh && bash check-php2shell.sh` as root.
It checks packages/changelog/signature/`rpm -V`, the fix marker (`zend_mm_safe_error_ex`) in every
engine binary, OOM behavior (CLI), session upload progress via php-cgi, and running processes
still mapping replaced PHP binaries. Exit 0 = protected, 1 = vulnerable/action needed,
2 = no php72u. Validated against IUS 7.2.34-1 and 7.2.31-1 (both FAIL), updated but not restarted
(FAIL on processes), and restarted (PASS).

## Test results (make test, CLI from the apache build)

| | passed | failed | xfail | skipped |
|---|---|---|---|---|
| unmodified IUS rebuild | 9311 | 12 | 34 | 6569 |
| patched | 9314 | 21 | 34 | 6601 |

The 12 shared failures come from the build environment, not the patches (expired openssl test certs,
date tests vs system tzdata, disk_free_space/stat in a container). The 9 patched-only failures are
the intended 0159 behavior changes: 8 × `ext/session/tests/rfc1867*.phpt` (upload progress now
disabled) and `tests/lang/bug45392.phpt` (OOM output path, one blank line differs).

`build/verify.sh out-rpms`: all 73 bundled modules load, `max_multipart_body_parts` present,
`php-fpm -t` OK, `httpd -t` OK with mod_php/prefork. The php2shell check gives exit=1 and no shutdown
function (unpatched baseline: SHUTDOWN-RAN, exit=255). Not tested: the client's own pecl modules
(ABI-additive, so expected to load) and FPM-SAPI-specific phpt tests (only run in the CLI build).

## Patches taken (spec Patch200–261)

The Debian patches were regenerated from a git tree of 7.2.34 + IUS patches, with NEWS
hunks dropped. All 62 applied with exact context (no fuzz, no 3-way merge).

| Ondřej # | Fix | CVE |
|---|---|---|
| 0057, 0059 | #77423 FILTER_VALIDATE_URL accepts invalid userinfo | CVE-2020-7071 |
| 0060 | #80672 NULL deref in SoapClient | CVE-2021-21702 |
| 0066 | #80710 imap_mail_compose() header injection | – |
| 0069, 0070 | #81122 SSRF bypass in FILTER_VALIDATE_URL | CVE-2021-21705 |
| 0071–0074 | #76448/76449/76450/76452 pdo_firebird overflows/crashes | CVE-2021-21704 |
| 0076, 0077 | #81211 symlinks followed when creating PHAR | – |
| 0079 | #81026 PHP-FPM OOB R/W in root process (priv-esc) | CVE-2021-21703 |
| 0082 | #81420 ZipArchive::extractTo path traversal | CVE-2021-21706 |
| 0084 | #79971 special chars break path in XML functions | CVE-2021-21707 |
| 0089 | #81720 uninitialized array in pg_query_params() | CVE-2022-31625 |
| 0090 | #81719 mysqlnd/pdo password buffer overflow | CVE-2022-31626 |
| 0093 | #81727 don't mangle `__Host-`/`__Secure-` cookie names | CVE-2022-31629 |
| 0094, 0095 | #81726 phar wrapper DoS with quine gzip | CVE-2022-31628 |
| 0097 | #81738 SHA-3 buffer overflow in hash_update() | CVE-2022-37454 |
| 0098 | #81740 PDO::quote() may return unquoted string | CVE-2022-31631 |
| 0100, 0101 | #81744 malformed bcrypt hashes / crypt overread | CVE-2023-0567 |
| 0102 | #81746 1-byte overrun appending slash to paths | CVE-2023-0568 |
| 0104, 0105 | multipart body DoS, adds `max_multipart_body_parts` | CVE-2023-0662 |
| 0108, 0109 | SOAP HTTP Digest: missing randomness check | CVE-2023-3247 |
| 0111 | phar_dir_read() buffer mismanagement | CVE-2023-3824 |
| 0112–0114 | XXE: libxml2 global state not sanitized | CVE-2023-3823 |
| 0116 | #79412 opcache 100% CPU on specific script | – |
| 0119 | `__Host-`/`__Secure-` cookie bypass (partial 2022 fix) | CVE-2024-2756 |
| 0121 | password_verify() can return true on error | CVE-2024-3096 |
| 0123 | filter_var FILTER_VALIDATE_URL bypass | CVE-2024-5458 |
| 0125 | CGI argument injection (Windows only, harmless here) | CVE-2024-4577 |
| 0127, 0130, 0132 | erroneous multipart form-data parsing | CVE-2024-8925 |
| 0128 | CGI param injection (CVE-2024-4577 bypass) | CVE-2024-8926 |
| 0129 | cgi.force_redirect bypass via env var collision | CVE-2024-8927 |
| 0133, 0134, 0135 | dblib/firebird quoter integer overflow (+ ZSTR_MAX_LEN) | CVE-2024-11236 |
| 0136 | HTTP stream proxy `request_fulluri` CRLF injection | CVE-2024-11234 |
| 0137 | OOB access in ldap_escape() | CVE-2024-8932 |
| 0138, 0139 | convert.quoted-printable-decode 1-byte overread | CVE-2024-11233 |
| 0140 | heap UAF in sapi_read_post_data | GHSA-4w77-75f9-2c8w |
| 0146 | heap overflow in array_merge() | CVE-2025-14178 |
| 0148 | SOAP stale ref_map pointer with Apache Map | CVE-2026-6722 |
| 0149 | SOAP UAF after header parse failure (SOAP_PERSISTENCE_SESSION) | CVE-2026-7261 |
| 0150 | SOAP Apache map NULL check | CVE-2026-7262 |
| 0151 | metaphone signed integer overflow | CVE-2026-7568 |
| 0152 | FPM status page XSS | CVE-2026-6735 |
| 0154 | openssl_encrypt() heap overflow with AES-WRAP-PAD | CVE-2026-14355 |
| 0155 | bundled libgd GIF reader | CVE-2026-9672 |
| 0156 | pgsql SQL injection via `E'...'` backslash breakout | CVE-2026-17543 |
| 0157 | phar recursive symlink crash | CVE-2026-7260 |
| 0159 | state corruption via bailout (Zend core) | CVE-2026-109618, CVE-2026-109619 |

IUS-specific fix (not in Ondřej's set because Debian uses a different tzdata patch):
`php-7.2.16-systzdata-v17.patch` allocated `3n + 7` bytes but writes a 10-byte header in
`fake_data_segment()`, a 3-byte heap overflow at timezone-db init. Fixed the same way as Remi.

Remi's 7.2.34-29 has no fix that isn't above. Ondřej's 0159 (Oct 18 2026) is newer than Remi's latest.

## Not taken

- 0001–0050, 0052–0056: Debian packaging (paths, libtool, multiarch, Debian-specific SAPI config)
- NEWS-only patches and NEWS hunks
- 0051 (#79296 empty-file ZipArchive, needs system libzip ≥ 1.6), 0092 (OpenSSL 3 EOF),
  0086–0088 (OpenSSL 3 / ICU ≥ 70), 0062–0063 (enchant-2), 0142 (newer glibc readdir_r),
  0143 (litespeed), 0145 (newer libxml2): compat for newer libraries than EL7 has
- 0064, 0065, 0068, 0118: Debian packaging credits
- 0117: changes opcache's default optimization level, a behavior change and not a security fix
- **0144: "secure DNS telemetry"**. At FPM/mod_php startup it sends an encrypted DNS TXT query
  with package and version to a build-time host. It's dormant in Ondřej's build (no `TELEMETRY_HOST`)
  but adds a libsodium link and a phone-home code path. Not wanted on a client box.

## Behavior changes to tell the client about

- `FILTER_VALIDATE_URL` rejects URLs with invalid userinfo (0059, 0069, 0123).
- New INI `max_multipart_body_parts` (default -1 = `max_file_uploads + max_input_vars`).
  Multipart requests with more parts are rejected (0105).
- Cookies whose names start with `__Host-`/`__Secure-` are handled per spec (0093, 0119).
- `pg_convert()`/`pg_insert()`/`pg_update()` quote strings with `'...'` not `E'...'` (0156).
- 0159 touches Zend core (allocator, hash, VM, shutdown, rfc1867). It's the broadest and
  newest patch, so soak it on staging before production.

## ABI

Header changes are additive only: new macros (`ZSTR_MAX_LEN`, `PHP_LIBXML_SANITIZE_GLOBALS`), inline
helpers, and new exported functions (`_array_init_singleton`, `zend_mm_safe_error_ex`). No struct
layouts or existing signatures change, and PHP_API/ZEND_MODULE_API numbers are unchanged. Existing
IUS-built pecl modules (`php72u-pecl-*`, ioncube) keep loading without a rebuild.

## Still unpatched (out of scope for this package)

- Bundled PCRE 8.x (`ext/pcre/pcrelib`), bundled libzip, bundled libmbfl: IUS builds with the
  bundled copies on EL7; Ondřej links system libs, so his series doesn't touch these.
- System libs from EL7/EPEL7 (openssl 1.0.2k, libxml2 2.9.1, oniguruma 5.9.5, curl 7.29): frozen
  since CentOS 7/EPEL 7 EOL (June 2024).
- The OS itself: CentOS 7 is EOL. This buys time; it is not a substitute for migrating.

## php71u -> php72u migration (`repo/migrate-php71-to-72.sh`)

For servers still on IUS php71u (update.sh does nothing there: php71u and php72u conflict).
`--check-only` shows the plan; otherwise: add repo, map each installed `php71u-X` to `php72u-X`
(aborts before any change if one has no twin in el7-repo, e.g. pecl modules, mcrypt), back up
`/etc/php*` to `/root/php71u-backup-*.tar.gz`, one `yum swap`, restart php-fpm/httpd, run
check-php2shell with evidence. `libargon2` (EPEL, re-signed, in `extras/`) ships in the repo since
php72u needs it and php71u servers lack it. Tested in a container on IUS 7.1.33 (cli, common, fpm,
mod_php, gd, json, mbstring, mysqlnd, opcache, pdo, xml): PROTECTED afterwards. It is a minor-version
upgrade (7.1 -> 7.2), so the app needs testing; the script does not test the application.

## centos7-repo-cleanup.sh (`repo/`)

Repoints dead CentOS 7 repos so yum works again (prerequisite for php71->72 migration on old
servers). Per enabled repo: works already -> untouched; known id (base/updates/extras/centosplus/
fasttrack/cr -> mirror.nsc.liu.se centos-store/centos/7; sclo-rh/sclo-sclo -> vault.centos.org 7.9.2009;
epel -> archives.fedoraproject.org; ius -> vault.ius.io) -> baseurl replaced, old line kept as
`#cleanup#`; unknown dead repo -> asked, then `enabled=0` (`-y` = no prompt, `--dry-run` = report only).
Backup in `/root/yum.repos.d-backup-*`. Tested in a stock centos:7 container with epel/ius/remi.
