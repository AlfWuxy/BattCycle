# Security policy

## Supported versions

| Version | Security updates |
|---|---|
| main and the latest tagged source release | Supported |
| Older commits and local forks | Best effort |

No notarized binary release is currently supported.

## Report a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/AlfWuxy/BattCycle/security/advisories/new). Avoid a public issue when a report could help someone execute commands, cross a privilege boundary, tamper with recovery, or expose local data.

Include:

- affected commit or release
- macOS and hardware version
- exact reproduction steps
- expected and observed behavior
- security impact
- logs with personal paths and identifiers removed
- a proposed fix, if available

The maintainer will acknowledge a complete report as availability allows, validate it, and coordinate a fix and disclosure. Please allow time for a safe response before publishing details.

## Security model

BattCycle runs as the logged-in user. It delegates adapter control to a separately installed official batt daemon and ships no custom root helper. Its per-user lock coordinates one account; the supported Start flow additionally refuses a different active console account. The daemon remains the machine-wide adapter authority. Stop and Restore are never blocked by the console-account check. Its core security properties are documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

High-impact areas include:

- command or configuration injection
- replacement of trusted executables or bundled scripts
- Python imports from an inherited or attacker-writable working directory
- symlink and file-permission attacks on runtime state
- writable packaging parents or replaced temporary build directories
- concurrent adapter control from different local accounts
- bypass of the 24-hour or 20% limits
- false success after adapter recovery failure
- accidental hardware activation during tests
- unauthorized future cross-device commands

## Dependency reports

For vulnerabilities in batt, stress-ng, MLX, Swift, or macOS, report directly to the relevant upstream project or vendor. If BattCycle makes an upstream weakness exploitable in a new way, also report it privately here.

## Secrets and personal data

Never include credentials, Apple IDs, private keys, device serial numbers, or unredacted personal paths in an issue or pull request. This repository should contain no production secrets.
