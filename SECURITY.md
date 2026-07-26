# Security Policy

## Supported versions

x120x-dkms is maintained as a personal open-source project.  Only the
**latest released version** receives fixes.  Please reproduce on the
latest release before reporting.

| Version        | Supported |
|----------------|-----------|
| latest release | ✅        |
| older releases | ❌        |

## Reporting a vulnerability

Please report security issues **privately** through GitHub's private
vulnerability reporting: the repository's **Security** tab →
**Report a vulnerability**.  This keeps the report confidential until a
fix is available.

Do **not** open a public issue for a security report.

## Response expectations

This is a personal project maintained on a best-effort basis — there is
no SLA.  Reports will be acknowledged and addressed as time permits, and
reporters credited in the release notes unless they prefer otherwise.

The driver runs in kernel space on single-board computers, so the most
relevant surface is **local**: sysfs writes, module parameters, and the
installer/uninstaller's file handling.  The v0.4.6 entry in [CHANGELOG.md](CHANGELOG.md) has a
"Security" section listing the hardening already applied.
