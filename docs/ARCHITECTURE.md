# Architecture and trust boundaries

## Overview

BattCycle separates user interaction, cycle coordination, stress workloads, and privileged adapter control. The repository owns only unprivileged components.

    User
      |
      v
    SwiftUI app --> validated config --> battcycle CLI --> cycle engine
         |                                              |     |      |
         +---- liveness + thermal heartbeat ------------+     v      v
                                                        IOKit stress batt client
                                                     caffeinate MLX      |
                                                                         v
                                                                 official batt daemon
                                                                         |
                                                                         v
                                                                 adapter hardware

The official batt daemon is outside this repository and is the only component expected to hold adapter-control privilege. BattCycle does not install that daemon, ship a root helper, invoke sudo, or mutate macOS power settings.

## Components

| Component | Responsibility | Privilege |
|---|---|---|
| BattCycle SwiftUI app | Configuration, status, confirmation, start, stop, restore | Logged-in user |
| BattCycleCore | Configuration validation, paths, battery snapshots | Logged-in user |
| battcycle CLI | Doctor, lifecycle commands, state display | Logged-in user |
| Cycle engine | State machine, process lifecycle, bounded adapter requests | Logged-in user |
| engine_lock and process_group_marker | Descriptor-held singleton, token binding, exact PGID identity | Logged-in user |
| active_console_users | Start-time check for a different macOS console account | Logged-in user |
| stress-ng and MLX | CPU and GPU workload | Logged-in user |
| macOS IOKit and caffeinate | Read battery state and prevent idle system sleep | Logged-in user |
| Official batt client and daemon | Adapter enable and timed disable | External trust boundary |

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

## Process and timeout model

- `bounded_exec.py` gives every shell call to batt a 4-second deadline, followed by TERM, a 1-second grace period, KILL, and direct-child reaping.
- The Swift command runner uses isolated system Python plus `process_group_exec.py` to create a dedicated session for each command, fixes the child working directory to `/`, and excludes inherited Python path variables. Preflight calls have 3- or 5-second limits, Start has 12 seconds, and Stop or Restore has 75 seconds. A timeout terminates the whole command group.
- `engine_lock.py` acquires advisory kernel locks for the private support directory and `run.lock` before engine execution, writes a random instance token and owner metadata, publishes the PID atomically, and passes both inheritable lock descriptors to the engine. The directory lock remains a stable singleton anchor if the `run.lock` pathname is removed or replaced.
- Before adapter disable, workload launch, each main-loop pass, and each one-second wait tick, the engine asks `engine_lock.py verify-held` to prove that its inherited directory and file descriptors still match the current paths, that the lock inode has exactly one link, and that its token matches the owner metadata. Losing that binding ends the engine through cleanup; adapter enable remains available during recovery.
- The detached cycle engine is a session and process-group leader, so its PID equals its PGID. `process_group_marker.py --role engine --instance-token <token>` gives recovery an exact engine-group identity. The stress workload runs in a separate PGID with the corresponding `--role workload` marker.
- `engine_lock.py owner --with-token` returns an owner only while the lock is genuinely busy. Stop and Restore treat the unique current-token workload marker as the recovery identity authority; a safely parsed `stressPgid` is supporting state and may be absent or stale. Marker discovery requires the current numeric EUID plus the exact interpreter, script path, role, token, and non-zombie state. Ambiguous identity prevents signaling, while adapter recovery still runs and the command returns failure.
- The engine EXIT trap launches the same script in cleanup mode in an independent process group. The parent gives it an 18-second primary completion window, followed by bounded TERM and KILL convergence checks. Cleanup-child exit 0 means complete cleanup success and is independent of the engine's original exit status. A contained nonzero exit or timeout starts one fresh, bounded independent cleanup attempt before the original engine's final in-process fallback. A cleanup group that still cannot be contained blocks concurrent fallback and keeps the inherited lock. The final result preserves the original engine failure, and fallback failure forces failure. No writable cleanup-completion marker file participates in this decision.
- Known engine and workload PGIDs are queried directly instead of repeatedly enumerating the complete macOS process table. Session startup temporarily follows the known leader PID until `setsid()` publishes the new PGID.
- Before App dependency probes, CLI dependency checks, or detached fork, `active_console_users.py` uses the fixed `/usr/bin/who` command and allows zero console sessions or only the current account. A different active console account rejects Start. This closes the supported Start-time overlap path while preserving Stop, Restore, cleanup, and CI without a GUI session. The per-user lock is not represented as a daemon-level machine lease.
- Process-state lookup failures are treated as active. TERM and KILL polling are bounded, and `wait` is used only after a child is confirmed gone or zombie.
- `SIGKILL` cannot run cleanup. Stop and Restore validate token-bearing engine and workload markers, terminate the authenticated groups, and then restore and verify adapter power.

## Local data

| Data | Default location | Expected protection |
|---|---|---|
| Configuration | ~/Library/Application Support/BattCycle/config.json | User-only |
| Runtime lock, PID, and stop request | ~/Library/Application Support/BattCycle/ | User-only |
| State snapshot, including active stress PGID | ~/Library/Application Support/BattCycle/state.json | User-only |
| App liveness and thermal heartbeat | ~/Library/Application Support/BattCycle/guardian.json | User-only |
| Engine logs | ~/Library/Logs/BattCycle/ | User-only |

The source tree contains no runtime state. Tests redirect every path into a temporary directory.

## Security invariants

- Only a strict JSON schema is accepted.
- Thresholds, workload sizes, polling, and deadline are range checked.
- Upper and lower thresholds are separated by at least 5%.
- The deadline is in the future and no more than 24 hours away.
- Executables are selected from explicit trusted locations during normal use.
- Inline and dependency-probe Python runs in isolated mode, and App-launched commands use `/` as their working directory.
- Configuration values are passed as arguments or parsed values, never evaluated as shell code.
- BattCycle never creates a system daemon or writes to system locations.
- BattCycle never writes world-writable control files.
- Live directory and file lock descriptors plus a random instance token establish engine ownership. The engine continuously revalidates path, inode, link count, FD, and token before sensitive operations; exact current-EUID token-bearing markers bind recovery to the engine and workload PGIDs.
- Stop requests use an exclusive no-follow temporary file, fsync, and atomic replacement; recovery reads the workload PGID through a size-bounded, no-follow state parser.
- Adapter disable always uses batt's timed auto-enable mechanism.
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
- adapter status and timed disable syntax are available
- stress-ng is executable
- the user-local BattCycle MLX Python is executable
- MLX imports successfully
- the token-bearing process-group marker is executable
- caffeinate is executable; the Swift app reads battery state through IOKit

Preflight reads status only. It must never disable the adapter or start stress.

## Same-user command boundary

The Swift App is the supported ordinary Start surface because it supplies the visible confirmation and thermal heartbeat. The repository keeps `scripts/battcycle start` and lower-level helpers for internal composition, diagnosis, and hardware-free tests. Those scripts execute with the same logged-in-user authority, accept controlled test overrides, and do not constitute a separate authorization boundary. Direct script-driven hardware cycling is outside the supported ordinary workflow. The Start-time console guard reduces accidental cross-account overlap. It cannot prevent another daemon-authorized user from calling batt directly or logging in after the check, so machine-wide ownership belongs in the external daemon.

## Packaging boundary

The local bundle contains BattCycle code and its lifecycle scripts. batt, stress-ng, Python, and MLX remain external dependencies. Packaging requires the repository root and output directory to be current-user-owned and not group or other writable, rejects an extended ACL on the repository root, clears an inherited ACL from `dist`, normalizes the output directory to `0700`, and revalidates ACL-free repository, output, and temporary-directory identities before publication, rollback, and recursive cleanup. `dist/BattCycle.app.zip` is the canonical local transferable artifact. Local packaging uses ad-hoc signing for development, and acceptance is based on strict codesign verification of a clean ZIP extraction. The current public release is source-only. A public binary release requires a separate signing, notarization, and distribution review.

## iPhone boundary

No iPhone code or data transport exists in the current repository. A future read-only companion would sit beyond a new network or cloud boundary and therefore needs:

- explicit opt-in
- authenticated device pairing
- minimal status payloads
- revocation and data deletion
- replay and stale-state handling
- a separate security review

The Mac remains the sole execution authority.
