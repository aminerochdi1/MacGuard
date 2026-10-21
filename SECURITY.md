# Security Policy

## Supported versions
Only the latest release on `main` receives fixes.

## Reporting a vulnerability
Please do not open a public issue for security problems.

Report privately through GitHub: Security tab > "Report a vulnerability".

Include: what you found, steps to reproduce, macOS version and Mac model.
I will reply within 7 days and credit you in the changelog if you want.

## Scope
In scope: bugs that let MacGuard delete, kill or expose more than the user confirmed,
unsafe handling of paths or logs, or anything that could be abused by another local process.

Out of scope: missed miners or malware (detection is signal-based, not antivirus),
and anything that needs root access to the Mac.
