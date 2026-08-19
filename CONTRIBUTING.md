# Contributing to OpenCode Cross-Talk

Thanks for considering a contribution! This project is small but has
clear conventions. Please follow them so reviews go fast.

## Setup

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

This detects your OpenCode Desktop session and writes a git-ignored
`cross/cross.config.local.json` — your identity is never committed.

## Conventions

- **Language:** code and user-visible messages are in **English**.
  Data-format fields (`EN_VUELO`, `CONFIRMADO`, `ESTADO=`, `NACKED`)
  are part of the protocol and stay as-is.
- **Versioning:** bump the version in `CROSS_TALK.md` (header) and add a
  `CHANGELOG.md` entry on every behavior change.
- **Tests:** every behavior change ships with a test. Tests live in
  `cross/tests/T-*.ps1`, are self-contained (fixtures in `$env:TEMP`),
  and must pass in a clean publish template (`cross.config.json` with
  empty identity) — use the SKIP pattern for anything that needs a live
  OpenCode Desktop server or a real session.

## Running tests

```powershell
cd cross\tests
Get-ChildItem T-*.ps1 | ForEach-Object { powershell -NoProfile -ExecutionPolicy Bypass -File $_.FullName }
```

Expected in a clean environment: all suites pass, server-dependent
scenarios print `SKIP` messages.

## Pull requests

1. Describe what changed and why (reference CROSS_TALK.md sections).
2. Include the test(s) covering the change.
3. Confirm the full suite passes before opening the PR.

## Issues

Use the issue templates: `bug_report.md` for defects, `feature_request.md`
for enhancements. Include the output of `cross.ps1 --version` / `cross.ps1
whoami` and the failing test name when reporting bugs.