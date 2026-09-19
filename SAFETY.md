# Safety

BattCycle deliberately creates sustained load and consumes battery cycle life. Use it only when you have a specific, supervised reason to cycle a battery.

## Main risks

- Heat from sustained CPU and GPU work
- Faster battery wear from repeated charge and discharge
- Unexpected sleep, shutdown, or data loss at low charge
- Adapter power remaining disabled after an OS, daemon, or hardware failure
- Reduced performance and responsiveness during stress

The timed batt safeguard lowers recovery risk. It cannot cover every failure.

## Before every run

- Save open work and make a current backup.
- Place the Mac on a hard, dry, ventilated surface.
- Keep the lid open and vents unobstructed.
- Remove the Mac from bedding, bags, direct sunlight, and other heat sources.
- Inspect for swelling, odor, unusual heat, liquid damage, or a damaged charger.
- Confirm battcycle doctor passes.
- Review the upper, lower, and stop time.
- Stay close enough to observe the machine.

Do not run BattCycle on a damaged, swollen, recalled, or unusually hot battery. Stop using the Mac and contact Apple or a qualified service provider.

## Guardrails

BattCycle enforces:

- a 20% minimum lower threshold
- a 24-hour maximum deadline
- explicit confirmation before Start
- an explicit open-lid warning and start confirmation
- at least 5% separation between charge and discharge thresholds
- timed adapter disable through batt 0.8+ `--for` only (1–600 seconds; never an untimed disable)
- a fresh same-user App liveness and thermal heartbeat, with automatic stop on serious or critical macOS thermal state
- fail-closed cleanup after a disconnected power cable is observed; detection may take one polling interval plus a bounded batt call
- terminal cleanup when MLX exits nonzero or finishes within 5 seconds
- dependency checks before each run
- a Start-time check that refuses a different active macOS console account
- kernel-backed directory and file locks whose inherited descriptors, path inodes, link count, and random token are reverified throughout the sensitive lifecycle
- exact current-EUID token-bearing process markers for the engine PGID and the separate stress-workload PGID
- verified adapter-enable requests during cleanup
- adapter recovery before bounded local workload termination
- one fresh bounded independent cleanup attempt, followed by an idempotent in-process emergency fallback, when the primary cleanup child exits nonzero or times out
- visible recovery failures

BattCycle never changes pmset, never invokes sudo or launchctl, never installs a privileged helper or LaunchAgent, and never writes batt charge limits or a max-charge-watts setter.
It cannot detect the physical lid position, so keeping the Mac open remains the operator's responsibility.
The App is the supported Start path. Direct lifecycle scripts run with the same logged-in-user authority and are reserved for implementation, diagnosis, and hardware-free tests. The heartbeat coordinates liveness and heat handling; it does not authenticate a different local user or process security domain. The console check is evaluated before Start and does not replace machine-wide arbitration inside the external batt daemon. A user calling batt directly, a later account login, or daemon behavior outside this repository remains beyond this guard.
Restore Adapter is the highest-priority control: idle starts immediately; an in-flight restore ignores duplicates; any other busy transaction queues Restore after it finishes. Restore does not start a second adapter-disable. CLI adapter writes hold `control.lock`; a verified restore/enable increments `control.generation` so a late suspend cannot disable the adapter again.

## Stop and recovery

Use the app's Stop button first. From the source checkout:

    ./scripts/battcycle stop
    ./scripts/battcycle status

If adapter state needs recovery:

    ./scripts/battcycle restore
    batt status

While no cycle is running, a timed standalone cut is:

    ./scripts/battcycle suspend-adapter
    ./scripts/battcycle resume-adapter

`suspend-adapter` accepts 1–600 seconds (default 300) and always uses `batt adapter disable --for=`. Both standalone commands refuse when a cycle is running; use Stop or Restore instead. Start is refused while a timed suspend deadline in `adapter-suspend-until` is still valid and the adapter is not in use. `battcycle status` dumps the full batt JSON after local state — review it before sharing.

Recovery-enable does not require timed-disable support. A failed or timed-out disable can already have taken effect, so the CLI performs at most two bounded enable/status rounds and only clears its marker after verified adapter power. Unknown state remains visible. The App retries via the serialized CLI only after an outer timeout with confirmed old-process-group cleanup; unconfirmed cleanup retains the marker.

Advice in the dashboard is read-only. It never issues these commands.

The engine normally runs a separate cleanup-mode shell before it exits. It receives an 18-second primary completion window followed by bounded TERM and KILL convergence checks. Exit 0 means that cleanup completed, independent of the engine's original result. A contained nonzero exit or timeout starts one fresh bounded independent cleanup attempt; only a second failure reaches the original engine's final idempotent fallback. A cleanup group that still cannot be contained blocks concurrent fallback and keeps the lock. Known PGIDs use direct process-group queries, while the known leader PID covers the brief `setsid()` startup window. The final status preserves the original engine failure, and fallback failure forces failure. `SIGKILL` cannot run an exit handler, so Stop and Restore obtain the token only from a genuinely busy lock, treat the unique current-EUID token-bearing workload marker as the recovery authority, terminate authenticated PGIDs, and then restore and verify adapter power. The state `stressPgid` remains supporting evidence and may be absent or stale. Ambiguous process identity is never signaled; adapter recovery is still attempted and the command reports failure. A forced group termination may return status 2 even after adapter recovery is verified; this preserves the fact that shutdown was abnormal.

Restore must report verified adapter power before you assume it is available. If recovery fails, stop the workloads, disconnect and reconnect the charger when safe, and follow the official batt recovery documentation. Keep monitoring the physical charging indicator.

For excessive heat, smoke, swelling, odor, or liquid:

1. Stop the run if the Mac is responsive.
2. Disconnect power when it is safe to do so.
3. Move away from combustible material without touching a swollen or leaking battery.
4. Follow local emergency guidance and Apple battery-service guidance.

## Monitoring clocks and advice

Three clocks stay independent:

| Clock | Interval | Role |
| --- | --- | --- |
| App guardian heartbeat | Fixed 2 seconds | Safety liveness and thermal coordination (`guardian.json`) |
| Engine poll | `pollSeconds` 5–60 in `config.json` | Cycle state machine |
| History recording | User-settable (presets 2 / 5 / 10 / 30 / 60 / 300 s, custom 2–3600 s) in `monitor.json` | Dashboard curves only |

Changing the history interval never relaxes the heartbeat or engine poll. Sleep must not fabricate history points; gaps are not treated as 0 W when estimating energy. History is local JSONL (`history/samples-YYYY-MM-DD.jsonl`); it is not written into the six-key `config.json`.

Older batt without `--for` disables adapter-off capability; it does not by itself prevent a supported recovery-enable attempt. It does not authorize untimed disable. Passive IOKit monitoring may still run.

## Testing policy

Run the current linked builds, unit tests, script mocks and packaging checks listed in [UI_VALIDATION.md](docs/UI_VALIDATION.md). The optional million-row synthetic JSONL probe is skipped by `BATTCYCLE_SKIP_PERF=1`; older compile-only runs and historical test counts are not acceptance for this revision.

Automated tests must use temporary directories and mocked tools. Tests, builds, packaging, CI, and app launch must never:

- disable the real adapter
- start a real stress workload
- install or modify a daemon
- invoke sudo
- invoke launchctl
- install a LaunchAgent or privileged helper
- write a batt charge limit
- change system power settings

Hardware acceptance is a separate, supervised procedure and must be labeled explicitly. Monitoring, history, and advice may be verified with mocks; that is not real-adapter acceptance.

## Health claims

BattCycle makes no promise to improve capacity, lifespan, calibration, or performance. Repeated cycling generally consumes battery life. Consult Apple documentation or a qualified technician for battery-health decisions.
