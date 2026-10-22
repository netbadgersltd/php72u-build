# Proving a server is patched against php2shell (CVE-2026-109618 / CVE-2026-109619)

`check-php2shell.sh` does not read the changelog and take the version's word for it. It triggers the
real vulnerable condition on the running engine and shows the fix neutralises it, and every probe is
**differential** — proven to report VULNERABLE on an unpatched build and PROTECTED on a fixed one.

## Why this proves patch status (and a live exploit would not)

A working exploit can only ever show a *failure to exploit*, and a failed exploit proves nothing: it
can miss because of heap layout, ASLR, a timeout, or a WAF while the bug is still present. So "we ran
an exploit and nothing happened" is not evidence of patching. The conclusive method is to show (a) the
vulnerable code path is actually exercised, (b) on an identical but unpatched server it behaves
dangerously, and (c) on this server it does not. That is what this script captures.

No code execution is attempted and no process memory is read or disclosed. It is safe on production:
no network, no service restarts, temp files in a private dir removed on exit.

## What each check demonstrates

1. **Fix compiled into every engine binary** — reads the `zend_mm_safe_error_ex` symbol straight from
   every `php`, `php-cgi`, `php-fpm`, `libphp7.so`, `phpdbg`, embedded binary on disk. Not the changelog.
2. **CVE-2026-109618, the bailout/state-corruption mechanism** — exhausts `memory_limit` through three
   different allocation paths (big allocation, array growth, with error/exception handlers registered),
   via both the CLI and the **CGI SAPI** that php-fpm/mod_php run. An unpatched engine `longjmp`s out
   (`zend_bailout`) and then runs the request-shutdown sequence over half-destroyed state — the exact
   corruption window — which the probe observes because registered shutdown code still executes. The
   fixed engine `_exit(1)`s and runs nothing. (This is the window behind the use-after-free and RCE.)
3. **CVE-2026-109619, upload-progress trigger** — sends the real multipart request that populates
   `session.upload_progress` state (on by default, the unauthenticated trigger for the memory
   disclosure / UAF). On an unpatched engine the state is populated; the fix suppresses it.
4. **Running processes** — flags any php-fpm/httpd/php worker still mapping the pre-update binary; those
   stay vulnerable until restarted even after the packages are updated.

## Producing the evidence for a client

```
# on the server, as root:
curl -fsSLO https://netbadgersltd.github.io/el7-repo/check-php2shell.sh
bash check-php2shell.sh --report php2shell-evidence-$(hostname -s).txt
```

This prints the full transcript and writes a timestamped report plus a `.sha256` sidecar. The report
records the host, date, kernel, the per-CVE behavioural results, and sha256 fingerprints of the actual
running binaries, so it is tied to a specific machine and tamper-evident
(`sha256sum -c php2shell-evidence-<host>.txt.sha256`). Exit code: 0 protected, 1 vulnerable/action
needed, 2 no php72u.

## The before/after that makes it conclusive

Run on one clean CentOS 7 host, stock IUS php72u then updated from el7-repo and restarted:

```
BEFORE (stock IUS)                               AFTER (el7-repo sec1, restarted)
RESULT: VULNERABLE (12 failed checks)            RESULT: PROTECTED against php2shell
  CVE-2026-109618 ... VULNERABLE (4 paths)         CVE-2026-109618: aborts safely in all 4 paths
  CVE-2026-109619 ... code path reachable          CVE-2026-109619: upload progress disabled
  engine binaries ... fix absent                   engine binaries ... fix present
```

Same OS, same probes, opposite results — the difference is the patch. Reproduce it yourself with
`build/Containerfile.client` (a plain CentOS 7 image) and the two package sets.

## Independent references the client can check

- PHP upstream commit "Avoid state corruption via bailout" (`712e60f9`), the fix this build backports.
- GHSA-w8hw-w9fx-j79w (CVE-2026-109618), GHSA-6wmf-4rv5-p3rp (CVE-2026-109619).
- AlmaLinux shipped the same backport independently (`php-7.2.24-1...alma.1`), compared in `../NOTES.md`.
- Full source + build recipe: https://github.com/netbadgersltd/php72u-build ; the source RPM
  is published at https://netbadgersltd.github.io/el7-repo/SRPMS/ . Rebuild it from the SRPM and compare, rather than trusting the binaries.
