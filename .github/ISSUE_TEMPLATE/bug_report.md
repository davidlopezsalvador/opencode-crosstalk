---
name: Bug report
about: Report a defect in CROSS-TALK
title: "[BUG] "
labels: bug
assignees: ''

---

**Describe the bug**
A clear and concise description of what is not working.

**To reproduce**
Steps to reproduce:
1. Command(s) run: `.\cross.ps1 ...`
2. Test suite / test name (if a test fails): `T-*.ps1`
3. Expected vs actual behavior

**Environment**
- PowerShell version: `$PSVersionTable.PSVersion`
- OpenCode Desktop version
- CROSS-TALK version: `.\cross.ps1 --version` (or commit hash)
- Is OpenCode Desktop running with sessions open? (yes/no)

**Output**
Paste the failing command output and, if relevant, the relevant lines of
`outbox.md` / `dlq-messages.md` / `audit_log.md`.

**Additional context**
Anything else that may help (config layout, number of sessions, etc.).
Do NOT paste `OPENCODE_SERVER_PASSWORD` or real session tokens.