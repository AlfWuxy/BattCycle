# Architecture and trust boundaries

## Overview

BattCycle separates user interaction, passive monitoring, cycle coordination, stress workloads, and privileged adapter control. The repository owns only unprivileged components.

    User
      |
      v
    SwiftUI dashboard (zh-Hans)
         |
         +-- IOKit BatterySnapshot / PowerMetrics (passive; battery W, ExternalConnected, rated Watts)
         +-- HistoryStore JSONL + AdviceEngine (read-only; never calls batt)
         +-- confirmed Start / Stop / Restore / timed suspend-adapter
         |
         v
    battcycle CLI --> cycle engine
         |                    |     |      |
         +-- guardian.json heartbeat (2s)  v      v
                                    IOKit stress batt client
                                 caffeinate MLX      |
                                                     v
                                             official batt daemon
                                                     |
                                                     v
                                             adapter hardware

The main window uses a six-section native sidebar and a pinned bottom Stop / Restore bar outside the scrolling detail pane. The minimum window size and independent scrolling preserve access to recovery controls. Cycle configuration is separate from standalone adapter control while both remain available.

The menu bar extra is in-process with the App. This round does not install a LaunchAgent, login item, or other out-of-process watcher.

The official batt daemon is outside this repository and is the only component expected to hold adapter-control privilege. BattCycle does not install that daemon, ship a root helper, invoke sudo, call launchctl, or mutate macOS power settings. Adapter disable is timed `--for` only (1–600 seconds, never beyond the run deadline).

Real adapter behavior with batt 0.8+ remains HOLD. Mock tests do not constitute device acceptance.

## Locked choices

These decisions are closed for this round. Do not reopen them without a new architecture review.

| Topic | Locked | Rejected |
|---|---|---|
| Dashboard chrome | Segmented top nav (wide: system segmented picker; narrow: wrapping chips) plus a pinned bottom Stop / Restore bar | `NavigationSplitView`, sidebar, or nested `TabView` that can hide Stop / Restore |
| History storage | Per-day JSONL samples, `monitor.json` settings, and `history/meta.json` sidecar counts | SQLite or any other database |
| Menu bar | In-process `NSStatusItem` in the App process (Open, Stop, Restore Adapter, Quit; no Start) | LaunchAgent, login item, or out-of-process watcher |
| Sampling clocks | Three decoupled clocks: guardian heartbeat 2 s, engine `pollSeconds`, history interval in `monitor.json` | Coupling heartbeat or engine poll to the history interval |
| Snapshot tick | One `batteryProvider.capture()` per tick, then `SnapshotTick.derive` | A second IOKit capture to assemble flow, metrics, history, or trust |
| Restore | Highest control priority: idle begins immediately; duplicate restore ignored; other busy transactions queue Restore after the current work finishes | Binding Restore enablement to `!busy`; preempting in-flight work; starting a second adapter-disable |
| Advice | Local read-only rules; never calls batt, stress, or adapter writes | Advice that actuates hardware or claims lifespan improvement |
| Real adapter | HOLD until supervised batt 0.8+ device checks | Claiming device acceptance from mock or unit tests |

## Components

| Component | Responsibility | Privilege |
|---|---|---|
| BattCycle SwiftUI dashboard | Native sidebar (six sections), monitoring, history, advice, confirmation, start, stop, restore, timed suspend | Logged-in user |
| In-process menu bar extra | Open, Stop, Restore Adapter, Quit; no Start; no LaunchAgent | Logged-in user |
| BattCycleCore | Config validation, paths, PowerMetrics, history, advice, capabilities | Logged-in user |
| AdviceEngine | Local read-only rules; no batt, stress, or adapter writes | Logged-in user |
| battcycle CLI | Doctor, status, stop, restore, suspend-adapter, resume-adapter | Logged-in user |
| Cycle engine | State machine, process lifecycle, bounded adapter requests | Logged-in user |
| engine_lock and process_group_marker | Descriptor-held singleton, token binding, exact PGID identity | Logged-in user |
| active_console_users | Start-time check for a different macOS console account | Logged-in user |
| stress-ng and MLX | CPU and GPU workload | Logged-in user |
| macOS IOKit and caffeinate | Read battery state and prevent idle system sleep | Logged-in user |
| Official batt client and daemon | Adapter enable and timed disable (`--for` required) | External trust boundary |

## State machine

    preflight
       | success
       v
    charging <---------------------+
       | upper reached             | lower reached
       v                           |
    discharging -------------------+
       |
       | stop or deadline
       v
    cleanup --> idle or failed recovery

The transition into discharging must send a timed adapter-disable request. Each window is capped at 600 seconds and cannot extend beyond the validated run deadline. Cleanup requests and verifies adapter enable before beginning bounded local workload termination.

Standalone `battcycle suspend-adapter` / `resume-adapter` use the same timed `--for` / enable path while the cycle is idle. They must refuse when the engine lock, PID, or identity marker shows a cycle in progress so they cannot preempt the state machine.

## Sampling clocks

Three clocks must stay decoupled:

| Clock | Source | Interval | Must not |
|---|---|---|---|
| Guardian heartbeat | App writes `guardian.json` | Fixed 2 seconds | Slow down when history is paused or the user picks a long history interval |
| Engine poll | `CycleConfig.pollSeconds` in `config.json` | 5–60 seconds | Drive dashboard curve density |
| History recording | `MonitorSettings.historyIntervalSeconds` in `monitor.json` | 2–3600 seconds (presets 2 / 5 / 10 / 30 / 60 / 300) | Relax heartbeat or engine poll; fabricate points during sleep |

Sleep and wake are observed by the App. Core recording logic marks a gap and records only real samples after wake. Missing watts and sleep gaps are not stored as 0 W and are not integrated as zero energy.

Each dashboard tick must call `batteryProvider.capture()` once and pass that snapshot to `SnapshotTick.derive`. `SnapshotTick` does not capture, write batt, or read IOKit. A second capture must not feed energy flow, PowerMetrics, history, or DataTrust.

## Metrics and capabilities

Dashboard metrics keep these fields distinct. Copying a battery-side watt reading into adapter-output, negotiated, or system-power slots is forbidden.

| Metric | Source | Notes |
|---|---|---|
| Battery percent and battery-side watts | IOKit `BatterySnapshot` | Watts are Voltage × InstantAmperage |
| Adapter physically connected | IOKit `ExternalConnected` | Not IOPS “AC Power” |
| System using adapter | IOPS Power Source State | Separate from physical connection |
| Adapter rated watts | `AdapterDetails` / IOPS `Watts` if present | Rated, not instantaneous output |
| Adapter output / negotiated / system power | Public IOKit keys often absent | Remain unavailable; never filled from battery watts |
| Engine adapter flags | `batt status --json` | `pluggedIn`, `useAdapter`, charge rate when present |
| Max charge power | JSON or IOKit only if a dedicated key exists | Readable at most; never writable |
| batt charge % cap | `configuration.upperLimitPercent` | Read-only; BattCycle never writes batt limits |
| Cycle upper/lower | Local `config.json` | Writable cycle thresholds, not batt limits |

`CapabilityInventory` assembles those facts for the UI. A control is writable only after a verified command exists. batt 0.8+ `--for` is required for adapter disable; older batt degrades that capability to unsupported.

## Process and timeout model

- `bounded_exec.py` gives every shell call to batt a 4-second deadline, followed by TERM, a 1-second grace period, KILL, and direct-child reaping.
- The Swift command runner uses isolated system Python plus `process_group_exec.py` to establish a dedicated process group for each command (creating a new session unless Foundation already assigned its child an isolated group), fixes the child working directory to `/`, and excludes inherited Python path variables. Preflight calls have 3- or 5-second limits, Start has 12 seconds, and Stop or Restore has 180 seconds. Standalone suspend has 135 seconds and resume has 100 seconds to accommodate the control-lock wait and bounded recovery. A timeout terminates and verifies containment of the whole command group; unconfirmed containment retains the recovery marker and does not launch a competing recovery command.
- Start retains `control.lock` until `engine_lock.py` has acquired both lifecycle locks. A same-PID trampoline then reaps its own control-lock child before executing the engine, preserving the inherited descriptors and token. Standalone suspend cannot enter a gap between releasing the control lock and acquiring the run lock.
- `engine_lock.py` acquires advisory kernel locks for the private support directory and `run.lock` before engine execution, writes a random instance token and owner metadata, publishes the PID atomically, and passes both inheritable lock descriptors to the engine. The directory lock remains a stable singleton anchor if the `run.lock` pathname is removed or replaced.
- Before adapter disable, workload launch, each main-loop pass, and each one-second wait tick, the engine asks `engine_lock.py verify-held` to prove that its inherited directory and file descriptors still match the current paths, that the lock inode has exactly one link, and that its token matches the owner metadata. Losing that binding ends the engine through cleanup; adapter enable remains available during recovery.
- The detached cycle engine is a session and process-group leader, so its PID equals its PGID. `process_group_marker.py --role engine --instance-token <token>` gives recovery an exact engine-group identity. The stress workload runs in a separate PGID with the corresponding `--role workload` marker.
- `engine_lock.py owner --with-token` returns an owner only while the lock is genuinely busy. Stop and Restore treat the unique current-token workload marker as the recovery identity authority; a safely parsed `stressPgid` is supporting state and may be absent or stale. Marker discovery requires the current numeric EUID plus the exact interpreter, script path, role, token, and non-zombie state. Ambiguous identity prevents signaling, while adapter recovery still runs and the command returns failure.
- The engine EXIT trap launches the same script in cleanup mode in an independent process group. The parent gives it an 18-second primary completion window, followed by bounded TERM and KILL convergence checks. Cleanup-child exit 0 means complete cleanup success and is independent of the engine's original exit status. A contained nonzero exit or timeout starts one fresh, bounded independent cleanup attempt before the original engine's final in-process fallback. A cleanup group that still cannot be contained blocks concurrent fallback and keeps the inherited lock. The final result preserves the original engine failure, and fallback failure forces failure. No writable cleanup-completion marker file participates in this decision.
- Known engine and workload PGIDs are queried directly instead of repeatedly enumerating the complete macOS process table. Session startup temporarily follows the known leader PID until `setsid()` publishes the new PGID.
- Before App dependency probes, CLI dependency checks, or detached fork, `active_console_users.py` uses the fixed `/usr/bin/who` command and allows zero console sessions or only the current account. A different active console account rejects Start. This closes the supported Start-time overlap path while preserving Stop, Restore, cleanup, and CI without a GUI session. The per-user lock is not represented as a daemon-level machine lease.
- Process-state lookup failures are treated as active. TERM and KILL polling are bounded, and `wait` is used only after a child is confirmed gone or zombie.
- `SIGKILL` cannot run cleanup. Stop and Restore validate token-bearing engine and workload markers, terminate the authenticated groups, and then restore and verify adapter power.
- Restore Adapter is the highest-priority control. From idle it begins immediately. A restore already in flight ignores duplicates. Any other busy transaction queues Restore to run after the current transaction finishes; Restore does not preempt in-flight work and must not start a second adapter-disable. Enablement uses `canRequestRestore` / `restoreArrival()`, not `!busy`, so a menu-bar Restore remains queueable during suspend.

Recovery-enable has a separate preflight from disable: missing timed-disable help does not block an enable attempt. Unknown/unreadable status permits bounded recovery; explicit unsupported/unauthorized capability remains a refusal. The standalone/Stop/Restore helper makes at most two enable/status rounds (each batt call has its own deadline), clears the marker only after verified power, and preserves visible failure otherwise. A nonzero or timed-out disable may already have taken effect, so it also enters bounded recovery.

## Local data

| Data | Default location | Expected protection |
|---|---|---|
| Cycle configuration (six keys only) | ~/Library/Application Support/BattCycle/config.json | User-only |
| Monitor settings | ~/Library/Application Support/BattCycle/monitor.json | User-only |
| History samples | ~/Library/Application Support/BattCycle/history/samples-YYYY-MM-DD.jsonl | User-only |
| History sidecar | ~/Library/Application Support/BattCycle/history/meta.json | User-only |
| Runtime lock, PID, and stop request | ~/Library/Application Support/BattCycle/ | User-only |
| State snapshot, including active stress PGID | ~/Library/Application Support/BattCycle/state.json | User-only |
| App liveness and thermal heartbeat | ~/Library/Application Support/BattCycle/guardian.json | User-only |
| Engine logs | ~/Library/Logs/BattCycle/ | User-only |

`config.json` remains the existing six-key schema: `upperLimit`, `lowerLimit`, `gpuSize`, `cpuJobs`, `pollSeconds`, `stopAtEpoch`. History interval and recording pause live in `monitor.json` and must not be added to `config.json`.

History storage is append-only per-day JSONL plus the `history/meta.json` sidecar (sample counts, byte estimates, per-file line counts). `sampleCount` and `estimatedBytes` read the sidecar rather than scanning every JSONL on each call. SQLite and other databases are out of scope.

Clear history deletes JSONL files and resets `history/meta.json`. It must not remove `config.json`, `monitor.json`, logs, locks, or the user-local MLX venv.

`battcycle status` concatenates local state with a full `batt status --json` dump. That dump is operator-private; see [PRIVACY.md](PRIVACY.md).

The source tree contains no runtime state. Tests redirect every path into a temporary directory. Energy Wh figures derived from history are **估算**; gaps are skipped rather than treated as zero.

## Security invariants

- Only a strict JSON schema is accepted for `config.json` (six keys) and a separate strict schema for `monitor.json`.
- Thresholds, workload sizes, polling, and deadline are range checked. History interval is range-checked independently and must not rewrite `pollSeconds`.
- Upper and lower thresholds are separated by at least 5%.
- The deadline is in the future and no more than 24 hours away.
- Executables are selected from explicit trusted locations during normal use.
- Inline and dependency-probe Python runs in isolated mode, and App-launched commands use `/` as their working directory.
- Configuration values are passed as arguments or parsed values, never evaluated as shell code.
- BattCycle never creates a system daemon, LaunchAgent, or writes to system locations.
- BattCycle never writes world-writable control files.
- BattCycle never writes batt charge limits or a max-charge-watts setter.
- Live directory and file lock descriptors plus a random instance token establish engine ownership. The engine continuously revalidates path, inode, link count, FD, and token before sensitive operations; exact current-EUID token-bearing markers bind recovery to the engine and workload PGIDs.
- Stop requests use an exclusive no-follow temporary file, fsync, and atomic replacement; recovery reads the workload PGID through a size-bounded, no-follow state parser.
- Adapter disable always uses batt's timed auto-enable mechanism (`--for`, 1–600 seconds). Untimed disable is not implemented.
- Standalone suspend/resume is refused while a cycle holds the engine.
- Restore Adapter is the highest-priority control and remains queueable while another transaction is busy; it must not be gated on `!busy`.
- AdviceEngine is display-only and has no hardware side effects. It must not call batt, start stress, or change adapter state.
- Each dashboard tick captures IOKit once; flow, metrics, history, and trust derive from that snapshot via `SnapshotTick.derive`.
- A disconnected power cable fails closed when observed by the next status snapshot.
- An MLX nonzero exit or completion within 5 seconds stops CPU load and ends the run without an MLX restart loop.
- The supported Start flow requires the App guardian. The engine checks its PID/path consistency, heartbeat freshness, and macOS thermal state at each one-second wait tick and each main-loop pass. A bounded external call can delay observation by up to its timeout. App and engine share the logged-in-user authority, so the guardian is liveness and thermal coordination rather than authentication between OS principals.
- Recovery errors propagate to the UI, CLI exit status, state, and logs.
- Cleanup-child exit 0 has one meaning: cleanup completed. A contained nonzero or timeout receives one fresh bounded cleanup attempt before the final in-process fallback, and marker shutdown failure retains failed state and PID evidence for later recovery.
- Unit and script tests replace hardware tools with mocks.
- The supported Start path refuses a different active console account before forking or acquiring the engine lock. Stop and Restore remain available regardless of later session changes.

## Dependency preflight

The doctor verifies:

- batt client version is 0.8.0 or later
- the batt daemon is reachable by the current user
- adapter status and timed disable syntax (`--for`) are available; older batt without `--for` fails doctor/Start and degrades adapter-disable capability
- stress-ng is executable
- the user-local BattCycle MLX Python is executable
- MLX imports successfully
- the token-bearing process-group marker is executable
- caffeinate is executable; the Swift app reads battery state through IOKit

Preflight reads status only. It must never disable the adapter or start stress.

## Same-user command boundary

The Swift App is the supported ordinary Start surface because it supplies the visible confirmation and thermal heartbeat. Supported CLI commands for operators are `doctor`, `status`, `stop`, `restore`, `suspend-adapter`, and `resume-adapter`. The repository keeps `scripts/battcycle start` and lower-level helpers for internal composition, diagnosis, and hardware-free tests. Those scripts execute with the same logged-in-user authority, accept controlled test overrides, and do not constitute a separate authorization boundary. Direct script-driven hardware cycling is outside the supported ordinary workflow. The Start-time console guard reduces accidental cross-account overlap. It cannot prevent another daemon-authorized user from calling batt directly or logging in after the check, so machine-wide ownership belongs in the external daemon.

## Packaging boundary

The local bundle contains BattCycle code and its lifecycle scripts. batt, stress-ng, Python, and MLX remain external dependencies. Packaging requires the repository root and output directory to be current-user-owned and not group or other writable, rejects an extended ACL on the repository root, clears an inherited ACL from `dist`, normalizes the output directory to `0700`, and revalidates ACL-free repository, output, and temporary-directory identities before publication, rollback, and recursive cleanup. `dist/BattCycle.app.zip` is the canonical local transferable artifact. Local packaging uses ad-hoc signing for development, and acceptance is based on strict codesign verification of a clean ZIP extraction. The current public release is source-only. Public notarized application remains HOLD. A public binary release requires a separate signing, notarization, and distribution review.

## iPhone boundary

No iPhone code or data transport exists in the current repository. A future read-only companion would sit beyond a new network or cloud boundary and therefore needs:

- explicit opt-in
- authenticated device pairing
- minimal status payloads
- revocation and data deletion
- replay and stale-state handling
- a separate security review

The Mac remains the sole execution authority.
