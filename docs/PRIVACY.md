# Privacy

BattCycle is designed for local operation. It has no account system, analytics SDK, advertising, telemetry endpoint, or cloud backend.

## Data inventory

BattCycle may store:

- cycle thresholds and workload settings
- scheduled stop time
- current phase and last update time
- local process identifiers
- App executable path and macOS thermal state in a short-lived local guardian heartbeat
- battery percentage and power-source observations
- diagnostic and recovery messages

It stores this information under:

- ~/Library/Application Support/BattCycle/
- ~/Library/Logs/BattCycle/

The app may also write local macOS unified log entries for launch and diagnostic events. Configuration files should never contain passwords, tokens, Apple IDs, device serial numbers, or health data.

## Network behavior

BattCycle itself does not require network access. Installing Homebrew packages, downloading Swift tools, or visiting GitHub may use the network as separate user actions.

The external batt daemon is maintained by another project. Review its current privacy and security behavior before installation.

## Sharing

BattCycle does not send logs or state to the maintainer. If you attach a log to a GitHub issue, review it first. File paths can reveal a macOS account name, and timestamps can reveal activity patterns.

## Retention and deletion

Runtime state remains until replaced by a later run or deleted by the user. Logs remain until the user removes them.

To remove BattCycle data, quit the app, confirm no cycle is running, then delete these BattCycle-only folders in Finder:

- Library/Application Support/BattCycle inside your home folder
- Library/Logs/BattCycle inside your home folder

Deleting the source or app bundle does not automatically delete runtime logs.

## iPhone and cloud status

The current release has no iPhone component, iCloud container, Shortcuts integration, or cross-device sync. Any future companion must be opt-in and will require an updated privacy notice before release.

## Questions

Open a GitHub discussion or issue for general privacy questions. Use the private process in [SECURITY.md](../SECURITY.md) when a report could expose sensitive data or a security weakness.
