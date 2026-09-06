# Privacy

BattCycle is designed for local operation. It has no account system, analytics SDK, advertising, telemetry endpoint, or cloud backend. It does not collect Apple IDs, device serial numbers, hardware UUIDs, or other identifiers for identity.

## Data inventory

BattCycle may store:

- cycle thresholds and workload settings (`config.json`, exactly six keys: `upperLimit`, `lowerLimit`, `gpuSize`, `cpuJobs`, `pollSeconds`, `stopAtEpoch`)
- monitor settings: history interval, recording paused, retention days (`monitor.json`)
- scheduled stop time
- current phase and last update time
- local process identifiers
- App executable path and macOS thermal state in a short-lived local guardian heartbeat
- battery percentage, battery-side watts, energy-flow direction, plug and adapter flags, thermal band, and engine phase in local history samples
- history sidecar counts (`history/meta.json`)
- adapter-control lock, generation, and timed-suspend deadline (`control.lock`, `control.generation`, `adapter-suspend-until`) — local operational files, not identity
- diagnostic and recovery messages

History files are local JSONL under `~/Library/Application Support/BattCycle/history/samples-YYYY-MM-DD.jsonl`. They are not written into `config.json`. Sample records must not include serial numbers, Apple IDs, device UUIDs, or unrelated filesystem paths.

It stores this information under:

- ~/Library/Application Support/BattCycle/
- ~/Library/Logs/BattCycle/

A scratch Swift build directory (for example `/tmp/BattCycle-release2.build` or `/tmp/BattCycle-fulltest2.build`) is a local compiler artifact. A locally packaged `dist/BattCycle.app` (ad-hoc codesign Identifier `org.alfwuxy.BattCycle`, not App Store signed) is a build output. Neither is runtime history, and neither is written into Application Support or Logs.

The app may also write local macOS unified log entries for launch and diagnostic events. Configuration files should never contain passwords, tokens, Apple IDs, device serial numbers, or health data.

## Network behavior

BattCycle itself does not require network access. Installing Homebrew packages, downloading Swift tools, or visiting GitHub may use the network as separate user actions.

The external batt daemon is maintained by another project. Review its current privacy and security behavior before installation.

## Sharing

BattCycle does not send logs, history, or state to the maintainer.

If you attach a log or history export to a GitHub issue, review it first. File paths can reveal a macOS account name, and timestamps can reveal activity patterns.

`./scripts/battcycle status` prints local engine state and then dumps the **full** `batt status --json` payload. That dump can include daemon configuration and charging fields that are not part of BattCycle's own schema. Treat it as operator-private output. Do not paste it into a public issue without redacting unexpected keys.

## Retention and deletion

Runtime state remains until replaced by a later run or deleted by the user. Logs remain until the user removes them. History retention (7 / 30 / 90 days) prunes old JSONL files locally.

Clear history in the App deletes `history/*.jsonl` and resets `history/meta.json`. It does not delete `config.json`, `monitor.json`, logs, locks, or the MLX virtualenv.

To remove all BattCycle data, quit the app, confirm no cycle is running, then delete these BattCycle-only folders in Finder:

- Library/Application Support/BattCycle inside your home folder
- Library/Logs/BattCycle inside your home folder

Deleting the source or app bundle does not automatically delete runtime logs or history.

## iPhone and cloud status

The current release has no iPhone component, iCloud container, Shortcuts integration, or cross-device sync. Any future companion must be opt-in and will require an updated privacy notice before release.

## Questions

Open a GitHub discussion or issue for general privacy questions. Use the private process in [SECURITY.md](../SECURITY.md) when a report could expose sensitive data or a security weakness.
