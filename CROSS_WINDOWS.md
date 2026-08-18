# OpenCode Cross-Talk — Pitfalls of PowerShell 5.1 / Windows

Environment-specific pitfalls (Windows + PowerShell 5.1), consolidated on
2026-08-11 after an external review (separated from `CROSS_TALK.md` on 2026-08-11
so that document contains only protocol rules). They are platform limitations,
NOT protocol limitations. Section 11 of `CROSS_TALK.md` references them
(items 1, 2, 7, 8) and delegates the details here.

1. **Corrupted JSON / HTTP 500** when using `-d '...'` inline in PowerShell: PS
   5.1 quoting corrupts the body. Use a temporary file + `--data-binary`
   (section 4) or the `send_message.ps1` wrapper (4e).
2. **Mojibake** (accents like `?`): API output is read in PS 5.1's cp850 even
   when the body is UTF-8. Send as plain ASCII and fix on integration; or read
   with `HttpClient`/`Invoke-RestMethod` which decode UTF-8 correctly.
3. **BOM in JSON → HTTP 500** (v1.5, tested 2026-08-10): generating the payload
   with `[System.Text.Encoding]::UTF8` (which writes a BOM) causes
   `HTTP 500 Unexpected server error`. Use UTF-8 without BOM or ASCII (section 4).
4. **`/tmp/` paths:** do not exist on Windows; use `$env:TEMP`.
5. **`&&` in PowerShell 5.1:** does not exist; use `;` or separate commands.
6. **`Add-Content` with concurrent writes** (finding T10, 2026-08-11): it is
   atomic (all-or-nothing) but uses exclusive locking per call; two processes
   writing at the same time → the second receives `IOException` and silently
   loses its line. That is why the outbox is updated ONLY by the sender (12.2);
   if real concurrent writes were needed, use append with retry and backoff or
   a lock file.
7. **`${var}:` interpolation** in PowerShell strings: `"${var}:foo"` is
   interpreted as a scoped variable `${var:}`; escape as `` `${var}`:foo ``.
8. **Windows Store Python stub:** `python` on the PATH in a normal shell is the
   Store alias and does NOT run; the real executable is at
   `AppData\Local\Python\pythoncore-3.11-64` (8.2). Specify full paths.
