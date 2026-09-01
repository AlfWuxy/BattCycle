# BattCycle product requirements

## Product statement

BattCycle is a local macOS app for supervised, time-bounded battery charge and discharge experiments. It provides a native start, stop, status, configuration, and recovery surface around an unprivileged local engine.

## Release truth

| Claim | State | Release consequence |
|---|---|---|
| macOS Swift package builds and tests | VERIFIED | Eligible for source release |
| Script behavior under controlled mocks | VERIFIED | Eligible for source release |
| Real adapter behavior with batt 0.8+ | HOLD | Do not claim device acceptance yet |
| Public notarized application | HOLD | Publish source only |
| iPhone companion | ROADMAP | Exclude from current feature claims |

## Goals

- Run a configurable upper-to-lower cycle on Apple Silicon Macs.
- Combine CPU and MLX GPU workloads during discharge.
- Provide a scheduled stop with a 24-hour hard limit.
- Restore adapter power on every normal stop path and surface failures.
- Keep all BattCycle-owned state in the user's Library.
- Keep the application process and engine fully unprivileged.
- Make build, test, security, privacy, and safety boundaries reviewable in a public repository.

## Non-goals

- Everyday charge limiting or battery-longevity optimization
- Warranty manipulation or intentional battery damage
- Closed-lid operation
- Silent or unattended execution
- Installation or management of batt's privileged daemon
- Modification of the user's existing batt charge limit
- iPhone control, iCloud sync, or remote execution in the current release
- Telemetry, analytics, accounts, or network services

## Supported environment

- Apple Silicon
- macOS 14 or later
- batt 0.8.0 or later with non-root client access to its daemon
- stress-ng
- a user-local BattCycle Python 3 virtual environment with MLX

The app must refuse Start when dependency checks fail.

## Default profile

- Upper threshold: 80%
- Lower threshold: 30%
- CPU workers: 4
- GPU workload: supported 2048 matrix size
- Poll interval: 10 seconds
- Stop time: next 07:00 local time
- Maximum duration: 24 hours
- Lid position: open

The lower threshold must remain at or above 20%, and the upper threshold must be at least 5 percentage points above the lower threshold.

## Core flow

1. The user reviews configuration and confirms Start.
2. BattCycle validates the configuration, requires no different active console account, and runs its dependency doctor.
3. The engine verifies its inherited singleton-lock descriptor and matching token before any hardware command.
4. While below the upper threshold, BattCycle leaves the adapter available and keeps stress workloads stopped.
5. At the upper threshold, BattCycle sends batt adapter disable with a bounded --for duration.
6. BattCycle starts user-owned stress-ng and MLX processes in a separate, token-marked workload PGID.
7. At the lower threshold, BattCycle stops the authenticated workload group, requests batt adapter enable, and verifies command success.
8. The cycle repeats until Stop or the scheduled deadline.
9. Cleanup records the final state and any recovery error. Cleanup-child exit 0 means complete cleanup success; a contained nonzero or timeout starts one fresh bounded independent cleanup attempt, and only a second failure reaches the idempotent in-process fallback while preserving the original engine failure status.

## Safety requirements

- The supported App Start flow is always user initiated and confirmed. Direct lifecycle scripts are internal, diagnostic, and test surfaces under the same user authority.
- Start must fail before fork, lock acquisition, or hardware calls when a different macOS console account is active. Stop, Restore, and cleanup must remain available.
- Automated tests may execute engine control code only against temporary paths and fake hardware or workload tools; they must never operate the real adapter or start real stress workloads.
- Local packaging must reject an extended ACL on the repository root, clear inherited ACLs from `dist`, and revalidate ACL-free build-directory identities before publication or cleanup.
- Every adapter-disable request includes a deadline no later than the run deadline.
- The cycle must stop within 24 hours.
- A stop request must be observable without administrator access.
- Cleanup errors must never be converted into success messages.
- Engine ownership must be proven by the inherited lock descriptor and token before adapter or stress operations.
- Stop and Restore must bind the lock-owner token to exact engine and workload marker arguments before signaling a PGID.
- The stress workload must use a separate PGID so cleanup can target it after engine-leader failure.
- Stop requests and workload-PGID state reads must use no-follow, size-bounded, atomic helpers rather than ad hoc control-file parsing.
- Ambiguous engine or workload identity must prevent signaling that group, continue adapter recovery, and return failure.
- Cleanup fallback must not depend on a writable completion-marker file; child exit 0 alone means complete cleanup success.
- BattCycle must never invoke sudo, launchctl, pmset mutation, or a custom root helper.
- BattCycle-owned directories must use user-only permissions.
- The app must not alter an existing batt charge limit.

## UX requirements

The main window shows:

- Current battery percentage and power source
- Engine phase and last update
- Upper and lower thresholds
- Scheduled stop
- CPU and GPU workload settings
- Dependency readiness
- Start, Stop, Restore, and Open Log controls
- A persistent heat and battery-wear warning

The menu bar may expose Open, Stop, Restore, and Quit. Starting from the menu bar is excluded so the confirmation and configuration remain visible.

## Storage and privacy

- Config and state: ~/Library/Application Support/BattCycle/
- Logs: ~/Library/Logs/BattCycle/
- No telemetry
- No account
- No cloud sync
- No network dependency in BattCycle itself

See [PRIVACY.md](PRIVACY.md).

## iPhone exploration

A separate future companion may show read-only state on an iPhone through an opt-in Shortcuts or iCloud transport. It must ship with a separate data-flow diagram, consent model, authentication design, and revocation path. The Mac remains the sole authority for adapter and workload control.

## Acceptance gates

### Source release gate

- Swift debug and release builds pass.
- Swift unit tests pass.
- Python and shell mock tests pass.
- Shell syntax and plist validation pass.
- Packaging produces `dist/BattCycle.app.zip` as the canonical transferable artifact, and a clean extraction passes strict codesign verification.
- Public secret and personal-data scans pass.
- The dependency-free CI scan of Git-tracked public text rejects high-confidence secrets and workstation-specific user-home paths without printing matched values.
- Security review finds no open critical or high-severity issue.
- Asset licensing is resolved.

### Hardware acceptance gate

- batt 0.8+ daemon access passes under a regular user.
- A supervised short run reaches adapter disable and enable.
- Timed adapter auto-enable is independently observed.
- Stop and Restore succeed during charge and discharge phases.
- Logs match the physical power state.

Until those device checks run, real hardware integration remains HOLD.
