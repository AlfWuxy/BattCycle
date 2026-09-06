# BattCycle product requirements

## Product statement

BattCycle is a local macOS app with three layers: monitor (passive battery monitoring), control (supervised active adapter and cycle control), and advice (read-only local advice). It provides a native dashboard (UI strings are zh-Hans) around an unprivileged local engine. Adapter privilege remains in a separately installed official batt 0.8+ daemon.

## Release truth

| Claim | State | Release consequence |
|---|---|---|
| macOS Swift package builds and tests | VERIFIED | Eligible for source release |
| Script behavior under controlled mocks | VERIFIED | Eligible for source release |
| Passive monitoring, local history, and advice | VERIFIED WITH MOCKS | Eligible for source release; does not prove device adapter behavior |
| Real adapter behavior with batt 0.8+ | HOLD (locked) | Do not claim device acceptance yet; mock and unit tests do not lift this HOLD |
| Public notarized application | HOLD | Publish source only |
| iPhone companion | ROADMAP | Exclude from current feature claims |

## Goals

- Show live IOKit energy-flow and power metrics without writing hardware.
- Record local history on an interval independent of the safety heartbeat and engine poll.
- Run a configurable upper-to-lower cycle on Apple Silicon Macs.
- Combine CPU and MLX GPU workloads during discharge.
- Provide a scheduled stop with a 24-hour hard limit.
- Restore adapter power on every normal stop path and surface failures.
- Offer timed standalone adapter suspend/resume only while no cycle is running.
- Offer local advice that never actuates hardware and never claims lifespan improvement.
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
- A max-charge-power slider, or any other writable max-charge-watts control
- Untimed adapter disable
- A LaunchAgent, login-item helper, or out-of-process menu bar in this round
- `NavigationSplitView`, a sidebar, or nested `TabView` chrome that can hide Stop / Restore
- SQLite or any database for history (JSONL + `monitor.json` + `history/meta.json` only)
- Fabricating history points across sleep or treating gaps as 0 W
- iPhone control, iCloud sync, or remote execution in the current release
- Telemetry, analytics, accounts, or network services

## Supported environment

- Apple Silicon
- macOS 14 or later
- batt 0.8.0 or later with non-root client access to its daemon **and** `adapter disable --for`
- stress-ng
- a user-local BattCycle Python 3 virtual environment with MLX

The app must refuse **Start** when dependency checks fail. Passive monitoring may continue when the batt daemon is unreachable; adapter-disable and adapter-enable controls must degrade to unsupported rather than invent a write path. Older batt without `--for` must not be treated as capable of untimed disable.

## Default profile

- Upper threshold: 80%
- Lower threshold: 30%
- CPU workers: 4
- GPU workload: supported 2048 matrix size
- Engine poll interval: 10 seconds (range 5–60)
- History interval: 10 seconds (presets 2 / 5 / 10 / 30 / 60 / 300; custom 2–3600), stored in `monitor.json`, independent of poll
- Guardian heartbeat: 2 seconds, not user-settable
- Stop time: next 07:00 local time
- Maximum duration: 24 hours
- Lid position: open
- Standalone adapter suspend: 300 seconds (range 1–600)

The lower threshold must remain at or above 20%, and the upper threshold must be at least 5 percentage points above the lower threshold.

Guardian heartbeat, engine poll, and history interval are three locked, decoupled clocks. The history interval must not relax the heartbeat or rewrite `pollSeconds`.

## Three-layer flow

The product is these three layers. The six sidebar sections are navigation, not extra product layers.

### Passive monitoring (monitor)

1. The App captures `BatterySnapshot` once per tick from IOKit, then derives flow, `PowerMetrics`, and trust through `SnapshotTick.derive`. That single capture is the source of battery-side watts, `ExternalConnected`, and `AdapterDetails` / IOPS `Watts` as rated adapter watts when present. A second capture must not feed those derived fields.
2. The cycle engine continues to read `batt status --json` for adapter and daemon fields. The dashboard must not copy battery watts into adapter-output or system-power fields.
3. History samples append to per-day JSONL when recording is not paused and the Mac is not asleep. Sleep leaves a gap; the App must not backfill points.
4. Energy watt-hours, means, and peaks derived from history are **估算**. Gaps are omitted from integration; missing watts are not zero.

### Active control (control)

1. The user reviews configuration and confirms Start.
2. BattCycle validates the configuration, requires no different active console account, and runs its dependency doctor.
3. The engine verifies its inherited singleton-lock descriptor and matching token before any hardware command.
4. While below the upper threshold, BattCycle leaves the adapter available and keeps stress workloads stopped.
5. At the upper threshold, BattCycle sends batt adapter disable with a bounded `--for` duration.
6. BattCycle starts user-owned stress-ng and MLX processes in a separate, token-marked workload PGID.
7. At the lower threshold, BattCycle stops the authenticated workload group, requests batt adapter enable, and verifies command success.
8. The cycle repeats until Stop or the scheduled deadline.
9. Cleanup records the final state and any recovery error. Cleanup-child exit 0 means complete cleanup success; a contained nonzero or timeout starts one fresh bounded independent cleanup attempt, and only a second failure reaches the idempotent in-process fallback while preserving the original engine failure status.
10. While idle, the user may confirm a timed `suspend-adapter` (1–600 s) or call `resume-adapter`. Both commands must refuse when a cycle is running.

### Advice (advice)

Advice evaluates local samples with deterministic rules. The Advice pane is display-only: it has no Start, Stop, Restore, adapter, or max-charge-power controls. It must not call batt, start stress, change adapter state, or claim that following it will extend battery life.

## Safety requirements

- The supported App Start flow is always user initiated and confirmed. Direct lifecycle scripts are internal, diagnostic, and test surfaces under the same user authority.
- Start must fail before fork, lock acquisition, or hardware calls when a different macOS console account is active. Stop, Restore, and cleanup must remain available.
- Automated tests may execute engine control code only against temporary paths and fake hardware or workload tools; they must never operate the real adapter or start real stress workloads.
- Local packaging must reject an extended ACL on the repository root, clear inherited ACLs from `dist`, and revalidate ACL-free build-directory identities before publication or cleanup.
- Every adapter-disable request includes a deadline no later than the run deadline and must use batt's timed `--for` mechanism. Untimed disable is forbidden.
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
- This round must not install a LaunchAgent. The menu bar extra is in-process with the App.
- Restore Adapter is the highest-priority control: idle begins immediately; a restore in flight ignores duplicates; any other busy transaction queues Restore after it finishes. Restore must not preempt in-flight work or start a second adapter-disable. Controls use `canRequestRestore`, not `!busy`.
- BattCycle-owned directories must use user-only permissions.
- The app must not alter an existing batt charge limit.
- Max charge power, when shown, is read-only or unsupported. It is never a slider. A mis-marked writable capability is still display-only. Absence of a key is not a write path.
- Guardian heartbeat must remain 2 seconds and must not be coupled to the user-settable history interval.
- `suspend-adapter` and `resume-adapter` must refuse while a cycle is running.
- Advice must remain display-only.

## UX requirements

The dashboard (zh-Hans) uses a native macOS sidebar with six destinations. Stop and Restore remain pinned outside the scrolling detail content, including in compact windows. System materials, semantic colors and system fonts support Light/Dark appearance.

The original three functional layers remain intact:

- Monitor: Battery overview and History, plus Settings and diagnostics for history interval, retention, exports, capabilities and logs.
- Control: Adapter control for standalone bounded suspend/resume, and Cycle experiment for thresholds, deadline and workloads. Separating these pages does not remove either workflow.
- Advice: read-only rules, supporting facts, confidence and suggested actions; no hardware writes or fabricated conclusions when data is insufficient.

See [the feature restoration map](FEATURE_RESTORATION.md) for the complete per-page inventory and its original source files. Both CSV entry points use the full-range export API, not downsampled chart points. Missing metrics retain their availability/source labels.

A persistent Stop and Restore Adapter control remains reachable even if monitoring or history I/O fails. Restore remains requestable while another control transaction is busy (queued, not preemptive). Starting from the menu bar is excluded so the confirmation and configuration remain visible. Missing metrics display as not provided or currently unavailable; they must not be filled with 0.

## Storage and privacy

- Cycle configuration: ~/Library/Application Support/BattCycle/config.json — exactly the six keys `upperLimit`, `lowerLimit`, `gpuSize`, `cpuJobs`, `pollSeconds`, `stopAtEpoch`
- Monitor settings: ~/Library/Application Support/BattCycle/monitor.json — not merged into `config.json`
- History: ~/Library/Application Support/BattCycle/history/samples-YYYY-MM-DD.jsonl
- History sidecar: ~/Library/Application Support/BattCycle/history/meta.json — counts and byte estimates for the JSONL files; not a database
- Runtime lock, PID, stop request, guardian heartbeat, state: ~/Library/Application Support/BattCycle/
- Logs: ~/Library/Logs/BattCycle/
- No telemetry
- No account
- No Apple ID, device serial, or hardware UUID in BattCycle-owned files
- No cloud sync
- No network dependency in BattCycle itself
- Clear history deletes JSONL and resets `history/meta.json` only
- History remains JSONL plus that sidecar; SQLite is not used

`battcycle status` may dump the full `batt status --json` document. Operators must be warned before sharing that output.

See [PRIVACY.md](PRIVACY.md).

## iPhone exploration

A separate future companion may show read-only state on an iPhone through an opt-in Shortcuts or iCloud transport. It must ship with a separate data-flow diagram, consent model, authentication design, and revocation path. The Mac remains the sole authority for adapter and workload control.

## Acceptance gates

### Source release gate

- Swift debug and release builds pass.
- Swift unit tests pass. Automated tests never operate the real adapter or start real stress workloads. This gate does not freeze a test count.
- Python and shell mock tests pass, including mocked `suspend-adapter` / `resume-adapter` (never a real adapter-off).
- Shell syntax and plist validation pass.
- Packaging produces `dist/BattCycle.app.zip` as the canonical transferable artifact, and a clean extraction passes strict codesign verification.
- Public secret and personal-data scans pass.
- The dependency-free CI scan of Git-tracked public text rejects high-confidence secrets and workstation-specific user-home paths without printing matched values.
- Security review finds no open critical or high-severity issue.
- Asset licensing is resolved.

Monitoring, history, and advice may be marked **VERIFIED WITH MOCKS** when those tests pass. That mark is not device acceptance.

### Hardware acceptance gate

- batt 0.8+ daemon access passes under a regular user.
- Timed `--for` disable is present in batt help.
- A supervised short run reaches adapter disable and enable.
- Timed adapter auto-enable is independently observed.
- Stop and Restore succeed during charge and discharge phases.
- Standalone timed suspend/resume is observed only while idle, and is confirmed refused while a cycle runs.
- Logs match the physical power state.

Until those device checks run, real adapter behavior remains HOLD. Passing the source-release suite does not lift that HOLD.
