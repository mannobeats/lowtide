# Security

Lowtide works close to the system: it removes files, runs an optional privileged helper,
captures packets, stores SSH credentials in the Keychain and updates itself. Security reports
are taken seriously and handled first.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub:
[Report a vulnerability](https://github.com/mannobeats/lowtide/security/advisories/new).

Include what you found, how to reproduce it, the Lowtide and macOS versions, and what an
attacker could do with it. You'll get an answer within a week. Once a fix is released, the
advisory is published with credit to you, unless you'd rather stay anonymous.

## Supported versions

Only the latest release gets security fixes. Lowtide updates itself (Settings › General ›
Updates), so most people are on it within a day of a release.

## How releases are protected

- Every release is built by [GitHub Actions](.github/workflows/release.yml) from a tagged
  commit, signed with a Developer ID, and notarized by Apple.
- Lowtide's updater installs a download only if it is signed by the same developer team as the
  running copy and passes Gatekeeper; otherwise it refuses and keeps the current copy.
- Each release lists SHA-256 checksums of its files in `SHA256SUMS`.
