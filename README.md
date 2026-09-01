# BattCycle

BattCycle is an open-source macOS utility for bounded battery charge and discharge experiments on Apple Silicon Macs. It combines a native SwiftUI control panel with local CPU and GPU workloads, a scheduled stop, and explicit recovery controls.

[![CI](https://github.com/AlfWuxy/BattCycle/actions/workflows/ci.yml/badge.svg)](https://github.com/AlfWuxy/BattCycle/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://support.apple.com/macos)

> [!CAUTION]
> Active cycling creates heat and consumes battery cycle life. BattCycle is intended for supervised experiments and troubleshooting. It is unsuitable as an everyday battery-health optimizer. Read [SAFETY.md](SAFETY.md) before the first run.

## Current status

| Surface | Status | Evidence |
|---|---|---|
| Swift package build and unit tests | VERIFIED | Local Swift build and test suite |
| Engine and CLI behavior | VERIFIED WITH MOCKS | Tests use fake batt and stress processes and never switch real hardware |
| App packaging | VERIFIED LOCALLY | Ad-hoc signed ZIP passes clean-extraction verification; no notarized binary is published yet |
| Real battery and adapter integration | HOLD | No supervised real-hardware acceptance run has been completed for 0.1.0 |
| iPhone support | ROADMAP | No iPhone app or cross-device sync ships in this repository |

## How it works

1. BattCycle waits while the Mac charges toward the configured upper threshold.
2. At the upper threshold, it asks the separately installed batt daemon to disable the adapter for a bounded duration, then starts stress-ng and an MLX workload.
3. At the lower threshold, on Stop, or at the scheduled deadline, it ends the workloads and verifies an adapter-enable request.
4. The loop may repeat until its deadline, with a hard maximum run window of 24 hours.

The safer default profile is 80% to 30%, four CPU workers, a moderate MLX matrix, and the next 07:00 local time. Keep the Mac lid open for the entire run.

BattCycle has no privileged helper, never invokes sudo, never changes pmset, and never edits your existing batt charge limit. Adapter control crosses the privilege boundary through the official [charlie0129/batt](https://github.com/charlie0129/batt) daemon, which you install and authorize separately.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Swift 6 toolchain for source builds
- [batt](https://github.com/charlie0129/batt) 0.8.0 or later, with regular-user daemon access
- stress-ng
- A user-local BattCycle Python 3 virtual environment with [MLX](https://github.com/ml-explore/mlx)

The supported setup uses Homebrew. Its batt service runs as root while exposing the daemon to regular users through the upstream `--always-allow-non-root-access` service option:

    brew install batt stress-ng python

Then review batt's official installation documentation and enable regular-user daemon access:

    sudo brew services start batt

Create the isolated MLX environment used by BattCycle:

    mkdir -p "$HOME/Library/Application Support/BattCycle"
    /opt/homebrew/bin/python3 -m venv "$HOME/Library/Application Support/BattCycle/venv"
    "$HOME/Library/Application Support/BattCycle/venv/bin/python3" -m pip install --upgrade pip mlx

These commands install external software and a privileged service outside BattCycle. Review the official batt and Homebrew instructions before running them. BattCycle itself does not install, upgrade, start, or reconfigure batt. A manual batt installation is an advanced route and must still place a compatible executable at `/opt/homebrew/bin/batt`; do not mix manual and Homebrew daemon installations.

Check readiness:

    ./scripts/battcycle doctor

The doctor must pass before the app will start a cycle. It also checks the Start-time console boundary: zero console sessions are accepted for CI and internal tests, while an interactive Mac may have only the current account logged in at the console. Stop and Restore remain available if another account logs in later.

## Build and run

Clone the repository and run the tests first:

    git clone https://github.com/AlfWuxy/BattCycle.git
    cd BattCycle
    swift build
    swift test
    /usr/bin/python3 -m unittest discover -s Tests/Scripts -p 'test_*.py'
    /bin/zsh Tests/Scripts/test_shell_mocks.sh

Build the local app bundle:

    /bin/zsh packaging/package_app.sh
    open dist/BattCycle.app

The script produces `dist/BattCycle.app.zip` as the canonical transferable artifact and also leaves an unpacked App for quick local preview. It requires the repository root and `dist` to belong to the current user without group or other write permission, rejects an extended ACL on the repository root, clears any inherited ACL from `dist`, normalizes safe `dist` permissions to `0700`, and revalidates ACL-free build-directory identity before publication, rollback, and cleanup. It strictly verifies the temporary App, a clean extraction of the temporary archive, and a clean extraction of the final published ZIP. The unpacked preview receives a standard signature check because an iCloud-managed Desktop may attach Finder metadata that makes strict verification unstable. Audit the clean ZIP extraction when checking the distributable. The repository currently publishes source code only.

## CLI

The app and its support CLI use the same engine:

    ./scripts/battcycle doctor
    ./scripts/battcycle status
    ./scripts/battcycle stop
    ./scripts/battcycle restore

The App is the only supported ordinary Start surface because it supplies confirmation plus a live thermal heartbeat. `scripts/battcycle start` and the lower-level scripts remain implementation and hardware-free test entry points under the same logged-in-user authority; invoking them directly is unsupported for ordinary use and does not create a separate authentication boundary. The guardian heartbeat coordinates same-user liveness and thermal safety. BattCycle refuses Start when `who` reports a different active console account. This is a Start-time safety prerequisite; the external batt daemon remains the machine-wide adapter authority.

Before any hardware command, the engine verifies that it inherited the live per-user singleton lock descriptor and matching random token. Engine and workload groups publish exact `process_group_marker.py` arguments containing that token. Stop and Restore obtain the owner token from a genuinely busy lock and treat the unique current-EUID token-bearing workload marker as recovery authority; the safely parsed recorded workload PGID is supporting evidence and may be absent or stale. Ambiguous identity prevents the corresponding signal, while adapter recovery is still attempted and the command reports failure. App commands run in dedicated process groups with deadlines, a fixed `/` working directory, and isolated Python import probes. None of these commands should trigger an administrator password prompt.

Runtime data is local:

- Configuration and state: ~/Library/Application Support/BattCycle/
- Logs: ~/Library/Logs/BattCycle/

See [docs/PRIVACY.md](docs/PRIVACY.md) for the complete data inventory.

## Safety guardrails

- A confirmation is required before each run.
- Lower thresholds below 20% are rejected.
- Upper and lower thresholds must remain at least 5% apart.
- Scheduled runs longer than 24 hours are rejected.
- Every shell call to batt has a 4-second deadline. A timeout sends TERM, allows 1 second for exit, then sends KILL and reaps the direct child.
- Adapter disable always includes batt's timed --for auto-enable safeguard, capped at 600 seconds and never beyond the run deadline.
- The engine requires a fresh App heartbeat and stops on serious or critical macOS thermal state. This heartbeat coordinates processes already running as the same user; it does not authenticate a separate OS principal.
- Kernel-backed directory and file locks prevent overlapping engines for the current account. Before Start, BattCycle also rejects a different active console account; machine-wide arbitration remains an external batt-daemon responsibility.
- Exact token-bearing markers identify the engine PGID and the separate workload PGID during Stop and Restore. Recovery does not rely on substring matching arbitrary command lines.
- A disconnected power cable fails closed at the next status snapshot. Observation may take up to roughly one polling interval plus one bounded batt call.
- An MLX nonzero exit or completion within 5 seconds is terminal for the run. BattCycle stops the CPU workload and enters cleanup without restarting MLX.
- The app refuses to start when the batt daemon, stress-ng, Python, or MLX checks fail.
- Cleanup failures are shown as failures and remain visible in logs.
- Cleanup requests adapter recovery first and bounds local process shutdown. Cleanup-child exit 0 alone means complete cleanup success, independent of the engine's original result. A contained nonzero exit or timeout starts one fresh bounded independent cleanup attempt; only a second failure reaches the idempotent in-process fallback. The final status still preserves the original engine failure, and fallback failure forces failure. The protocol does not use a writable cleanup-completion marker file.
- Tests use mocks and never operate the real adapter or launch stress workloads.

The timed safeguard reduces risk. It cannot guarantee recovery from every OS, firmware, power, or hardware failure. Stay nearby and monitor temperature.

## iPhone roadmap

BattCycle currently controls one Mac locally. A future iPhone companion may show read-only Mac status through an explicit, opt-in channel such as Shortcuts or iCloud. iOS cannot directly control a MacBook power adapter, and this repository contains no iPhone implementation today. Cross-device control will require a separate threat model and consent design.

## Project docs

- [Product requirements](docs/PRD.md)
- [Architecture and trust boundaries](docs/ARCHITECTURE.md)
- [Privacy](docs/PRIVACY.md)
- [Asset provenance](docs/ASSET_PROVENANCE.md)
- [Safety](SAFETY.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

BattCycle source code is available under the [MIT License](LICENSE). See [docs/ASSET_PROVENANCE.md](docs/ASSET_PROVENANCE.md) for non-code asset status.
