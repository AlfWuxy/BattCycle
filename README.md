# BattCycle

BattCycle is an open-source macOS utility for local battery monitoring, supervised charge/discharge experiments, and read-only advice on Apple Silicon Macs. The native SwiftUI dashboard (zh-Hans) sits in front of an unprivileged engine. Adapter control still crosses a privilege boundary only through a separately installed [batt](https://github.com/charlie0129/batt) 0.8+ daemon.

[![CI](https://github.com/AlfWuxy/BattCycle/actions/workflows/ci.yml/badge.svg)](https://github.com/AlfWuxy/BattCycle/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://support.apple.com/macos)

[View the source release](https://github.com/AlfWuxy/BattCycle/releases/tag/v0.1.0) · [Report a bug](https://github.com/AlfWuxy/BattCycle/issues/new?template=bug.yml) · [Suggest an idea](https://github.com/AlfWuxy/BattCycle/issues/new?template=feature.yml)

> [!CAUTION]
> Active cycling creates heat and consumes battery cycle life. Use BattCycle only while you can supervise the Mac. Save open work, keep the lid open, place the Mac on a hard ventilated surface, and read [SAFETY.md](SAFETY.md) before the first run. It is unsuitable as an everyday battery-health optimizer.

BattCycle has no privileged helper, never invokes sudo, never uses launchctl, never changes pmset, and never edits your existing batt charge limit. Adapter disable is timed `--for` only. This release does not install a LaunchAgent or root helper. Adapter control uses the official batt daemon, which you install and authorize separately.

## Complete battery workspace

The six-section native sidebar preserves the expanded monitoring suite as well as the original cycle experiment. Passive monitoring, history, and advice work without starting a cycle.

![Native battery overview with synthetic data](docs/screenshots/overview-light.png)

The full [feature restoration map](docs/FEATURE_RESTORATION.md) records what moved into each section. [Validation and screenshots](docs/UI_VALIDATION.md) distinguish code/mock evidence from real hardware acceptance. Local packaging is ad-hoc signed; this is not a notarized binary release. Native interactive clicks and real battery/adapter behavior require separate acceptance.

## Three layers

1. **Passive monitoring.** Live IOKit battery percentage, battery-side watts, energy-flow direction (charge / discharge / idle / unknown), adapter physically connected (`ExternalConnected`), and adapter rated watts from `AdapterDetails` / IOPS `Watts` when present. Missing keys stay missing. The dashboard does not invent wall-input or system power.
2. **Active control.** Confirmed Start Cycle, Stop, Restore Adapter, and optional timed adapter suspend/resume. Cycle thresholds, deadline, and workloads stay as before. The App is the ordinary Start surface.
3. **Advice (read-only).** Local rules over recent history. Advice never issues batt commands, never starts stress, and never claims to improve lifespan, capacity, or calibration.

Passive monitoring does not require a cycle to be running. Adapter disable requires batt 0.8+ with timed `--for`. Read-only IOKit monitoring remains available without it. Recovery-enable uses its own prerequisites so missing timed-disable support does not prevent a recovery attempt.

## Who it is for

- Developers testing power behavior under repeatable load.
- Hardware experimenters studying battery wear and charge/discharge timing.
- Performance testers comparing CPU-only, GPU-only, and combined load behavior.
- Owners who intentionally want to consume battery cycles for a controlled experiment.

BattCycle is a test and observation tool. It does not improve battery lifespan, capacity, calibration, or everyday charging habits.

## Monitoring dashboard

The App window is a native dashboard. UI strings are Simplified Chinese (zh-Hans). English documentation stays English.

Sidebar sections:

- **Battery overview (电池概览).** Live energy flow, battery percentage and net power, physical adapter connection versus adapter use, source-aware read-only metrics, thermal state, data trust, and last/next history sample.
- **History (曲线与历史).** Seven time-range choices including custom dates, percent/power charts, cursor inspection, events and gaps, watt-hour estimates, mean/peak power, adapter/battery durations, completeness, pause/resume recording, and full-range CSV export.
- **Adapter control (适配器控制).** Current status, supported capabilities, 1–600-second timed suspend with confirmation and automatic re-enable deadline, resume, command feedback and recovery guidance. Charge-power and charge-percent limits remain read-only.
- **Advice (使用建议).** Local read-only findings with observed facts, rule text, confidence, and suggested actions; insufficient data stays explicit.
- **Cycle experiment (循环实验).** Upper/lower thresholds, stop deadline, CPU/GPU settings, independent engine polling interval, reset defaults, and confirmed Start.
- **Settings and diagnostics (设置与诊断).** History interval presets/custom value, retention, sample count/storage, pause/resume, full-range CSV, confirmed history deletion, monitor reset, three-clock diagnostics, capability inventory, environment recheck and log access.

Stop and Restore Adapter stay reachable. Closing the window does not quit. The menu bar extra is in-process with the App (Open, Stop, Restore Adapter, Quit). There is no LaunchAgent in this round, and the menu bar cannot Start a cycle.

Max charge power is shown only when IOKit or `batt status --json` provides it. It is not writable. The batt charge-percentage cap is read-only. Cycle upper/lower thresholds in the App are local `config.json` values, not batt limit writes.

## One cycle

1. Charge toward the configured upper threshold.
2. At the upper threshold, request a timed adapter disable (`batt adapter disable --for=…`).
3. Run the selected CPU and GPU workloads while the battery discharges.
4. At the lower threshold, stop the workloads and restore adapter power.
5. Charge again and repeat until the deadline or a manual Stop.

The default profile cycles between 80% and 30%, uses four CPU workers and a moderate MLX matrix, and stops at the next 07:00 local time. A single run cannot exceed 24 hours.

## What it measures

| Signal | Current support |
| --- | --- |
| Battery percentage and power source | Live IOKit in the dashboard; engine also reads `batt status --json` |
| Instantaneous battery-side power | Live signed watt reading (battery Voltage × InstantAmperage), not adapter output |
| Adapter physically connected | IOKit `ExternalConnected` when the key is present |
| System using adapter | IOPS AC Power state, kept separate from physical connection |
| Adapter rated watts | `AdapterDetails` / IOPS `Watts` when present; not treated as instantaneous output |
| Adapter output, negotiated PD, or system power | Not provided by public IOKit keys; shown as unavailable, never copied from battery watts |
| Max charge power | View-only if JSON or IOKit provides a dedicated key; not writable |
| batt charge % cap | Read-only from `batt status --json` |
| macOS thermal pressure | Nominal, fair, serious, or critical |
| Local energy Wh / mean / peak | **估算** from history; sleep and missing samples are gaps, not zero |
| Exact battery, CPU, or GPU temperature | Not currently collected |
| Charger or wall-input power | Requires external measurement hardware |

## Sampling clocks

These clocks stay independent:

| Clock | Interval | Role |
| --- | --- | --- |
| App guardian heartbeat | Fixed 2 seconds | Safety liveness and thermal coordination (`guardian.json`) |
| Engine poll | `pollSeconds` 5–60 | Cycle state machine |
| History recording | User-settable (presets 2 / 5 / 10 / 30 / 60 / 300 s, custom 2–3600 s) | Dashboard curves only |

Changing the history interval never relaxes the heartbeat or engine poll. Sleep does not fabricate history points. Clear history deletes `history/samples-YYYY-MM-DD.jsonl` and resets `history/meta.json`; it does not delete `config.json`, `monitor.json`, logs, locks, or the MLX venv.

The optional million-row synthetic history probe is separate from the normal suite (`BATTCYCLE_SKIP_PERF=1`). Current measurements and their scope belong in the validation record; old workstation timings are not acceptance for this version.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- Swift 6 toolchain for a source build.
- [batt](https://github.com/charlie0129/batt) 0.8.0 or later with regular-user daemon access **and** `adapter disable --for`. Older batt without `--for` degrades adapter controls; it does not unlock untimed disable.
- `stress-ng`.
- A user-local Python environment with [MLX](https://github.com/ml-explore/mlx).

The supported setup uses Homebrew. Its batt service runs as root while exposing the daemon to regular users through the upstream `--always-allow-non-root-access` service option:

```bash
brew install batt stress-ng python
sudo brew services start batt
mkdir -p "$HOME/Library/Application Support/BattCycle"
/opt/homebrew/bin/python3 -m venv "$HOME/Library/Application Support/BattCycle/venv"
"$HOME/Library/Application Support/BattCycle/venv/bin/python3" -m pip install --upgrade pip mlx
```

These commands install external software and a privileged service **outside BattCycle**. Review the official batt and Homebrew instructions before running them. BattCycle itself does not install, upgrade, start, or reconfigure batt, and it does not invoke sudo. A manual batt installation is an advanced route and must still place a compatible executable at `/opt/homebrew/bin/batt`; do not mix manual and Homebrew daemon installations.

Check readiness:

```bash
./scripts/battcycle doctor
```

The doctor must pass before the app will start a cycle. It also checks the Start-time console boundary: zero console sessions are accepted for CI and internal tests, while an interactive Mac may have only the current account logged in at the console. Stop and Restore remain available if another account logs in later.

## Build and run

Clone the repository and run the tests first. Use the full linked debug/release builds, not a target-only compile. `BATTCYCLE_SKIP_PERF=1` skips the separate million-row history query benchmark.

```bash
git clone https://github.com/AlfWuxy/BattCycle.git
cd BattCycle
swift build
BATTCYCLE_SKIP_PERF=1 swift test
/usr/bin/python3 -m unittest discover -s Tests/Scripts -p 'test_*.py'
/bin/zsh Tests/Scripts/test_shell_mocks.sh
```

Build the local app bundle:

```bash
/bin/zsh packaging/package_app.sh
open dist/BattCycle.app
```

A sibling `packaging/package_app.sh` run produced `dist/BattCycle.app` (exit 0) with ad-hoc codesign Identifier `org.alfwuxy.BattCycle`. That is not App Store signed and is not notarized. The script produces `dist/BattCycle.app.zip` as the canonical transferable artifact and also leaves an unpacked App for quick local preview. It requires the repository root and `dist` to belong to the current user without group or other write permission, rejects an extended ACL on the repository root, clears any inherited ACL from `dist`, normalizes safe `dist` permissions to `0700`, and revalidates ACL-free build-directory identity before publication, rollback, and cleanup. It strictly verifies the temporary App, a clean extraction of the temporary archive, and a clean extraction of the final published ZIP. The unpacked preview receives a standard signature check because an iCloud-managed Desktop may attach Finder metadata that makes strict verification unstable. Audit the clean ZIP extraction when checking the distributable. The repository currently publishes source code only.

In the app:

1. Wait for the environment check if you intend to Start a cycle. Monitoring still works when the daemon is down; adapter writes will not.
2. Review Overview and History. Set the history interval independently of cycle poll seconds.
3. To run a cycle: choose the charge range, stop time, and optional CPU/GPU load, then press **Start Cycle** and confirm.
4. Use **Stop** to end a run. Use **Restore Adapter** if power needs to be re-enabled and verified.
5. Timed suspend/resume is available only while no cycle is running.

## CLI

The app and its support CLI use the same engine. Ordinary Start is the App.

```bash
./scripts/battcycle doctor
./scripts/battcycle status
./scripts/battcycle stop
./scripts/battcycle restore
./scripts/battcycle suspend-adapter [1-600]
./scripts/battcycle resume-adapter
```

`suspend-adapter` defaults to 300 seconds, accepts 1–600, always uses `batt adapter disable --for=<seconds>s`, and is refused while a cycle is running. `resume-adapter` is the matching standalone enable and is likewise refused during a cycle; use Stop or Restore instead.

`battcycle status` prints local engine state and then dumps the full `batt status --json` payload. Review that dump before sharing it; it can include daemon configuration beyond BattCycle's own files.

`scripts/battcycle start` and the lower-level scripts remain implementation and hardware-free test entry points under the same logged-in-user authority. Invoking them directly is unsupported for ordinary use and does not create a separate authentication boundary. The guardian heartbeat coordinates same-user liveness and thermal safety. BattCycle refuses Start when `who` reports a different active console account. This is a Start-time safety prerequisite; the external batt daemon remains the machine-wide adapter authority.

Before any hardware command, the engine verifies that it inherited the live per-user singleton lock descriptor and matching random token. Engine and workload groups publish exact `process_group_marker.py` arguments containing that token. Stop and Restore obtain the owner token from a genuinely busy lock and treat the unique current-EUID token-bearing workload marker as recovery authority; the safely parsed recorded workload PGID is supporting evidence and may be absent or stale. Ambiguous identity prevents the corresponding signal, while adapter recovery is still attempted and the command reports failure. App commands run in dedicated process groups with deadlines, a fixed `/` working directory, and isolated Python import probes. None of these commands should trigger an administrator password prompt.

Runtime data is local:

- Cycle config (exactly six keys: `upperLimit`, `lowerLimit`, `gpuSize`, `cpuJobs`, `pollSeconds`, `stopAtEpoch`): `~/Library/Application Support/BattCycle/config.json`
- Monitor settings: `~/Library/Application Support/BattCycle/monitor.json`
- History samples: `~/Library/Application Support/BattCycle/history/samples-YYYY-MM-DD.jsonl`
- History sidecar: `~/Library/Application Support/BattCycle/history/meta.json`
- Logs: `~/Library/Logs/BattCycle/`

History is local JSONL. It is not stored in `config.json`. See [docs/PRIVACY.md](docs/PRIVACY.md).

## Safety guardrails

- A confirmation is required before each cycle Start.
- Lower thresholds below 20% are rejected.
- Upper and lower thresholds must remain at least 5% apart.
- Scheduled runs longer than 24 hours are rejected.
- Every shell call to batt has a 4-second deadline. A timeout sends TERM, allows 1 second for exit, then sends KILL and reaps the direct child.
- Adapter disable always includes batt's timed `--for` auto-enable safeguard, capped at 600 seconds and never beyond the run deadline. Untimed adapter-off is not a BattCycle command.
- The engine requires a fresh App heartbeat (2 s) and stops on serious or critical macOS thermal state. This heartbeat coordinates processes already running as the same user; it does not authenticate a separate OS principal. History interval cannot slow that heartbeat.
- Kernel-backed directory and file locks prevent overlapping engines for the current account. Before Start, BattCycle also rejects a different active console account; machine-wide arbitration remains an external batt-daemon responsibility.
- Exact token-bearing markers identify the engine PGID and the separate workload PGID during Stop and Restore. Recovery does not rely on substring matching arbitrary command lines.
- A disconnected power cable fails closed at the next status snapshot. Observation may take up to roughly one polling interval plus one bounded batt call.
- An MLX nonzero exit or completion within 5 seconds is terminal for the run. BattCycle stops the CPU workload and enters cleanup without restarting MLX.
- The app refuses to start a cycle when the batt daemon, stress-ng, Python, or MLX checks fail.
- Cleanup failures are shown as failures and remain visible in logs.
- Cleanup requests adapter recovery first and bounds local process shutdown. Cleanup-child exit 0 alone means complete cleanup success, independent of the engine's original result. A contained nonzero exit or timeout starts one fresh bounded independent cleanup attempt; only a second failure reaches the idempotent in-process fallback. The final status still preserves the original engine failure, and fallback failure forces failure. The protocol does not use a writable cleanup-completion marker file.
- Standalone `suspend-adapter` / `resume-adapter` refuse to run while a cycle holds the engine.
- Restore Adapter is the highest-priority control and does not start a second adapter-disable. CLI adapter writes take `control.lock`.
- Advice never actuates hardware.
- Tests use isolated mocks and do not operate the real adapter or launch real stress workloads. Current results are recorded in [UI_VALIDATION.md](docs/UI_VALIDATION.md).
- Native view screenshots use labelled synthetic data. Real adapter hardware and native click acceptance remain unverified.

The timed safeguard reduces risk. It cannot guarantee recovery from every OS, firmware, power, or hardware failure. Stay nearby and monitor temperature.

## Product direction

Monitoring history, watt-hour **估算**, and local advice now ship in this tree. Remaining experiment-report work includes richer baselines, optional component-power collectors, separate Cycle Burn / Power Sweep / Thermal Soak modes, and a read-only iPhone companion. None of those items changes the separate acceptance required for real adapters and notarized binaries.

## Technical docs

- [Feature restoration map](docs/FEATURE_RESTORATION.md)
- [Current validation and screenshots](docs/UI_VALIDATION.md)

- [Product requirements](docs/PRD.md)
- [Architecture and trust boundaries](docs/ARCHITECTURE.md)
- [Safety and recovery](SAFETY.md)
- [Privacy](docs/PRIVACY.md)
- [Asset provenance](docs/ASSET_PROVENANCE.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

BattCycle source code is available under the [MIT License](LICENSE). See [asset provenance](docs/ASSET_PROVENANCE.md) for non-code asset status.
