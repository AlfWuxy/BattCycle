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
- timed adapter disable through batt 0.8+
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

BattCycle never changes pmset and never installs a privileged helper.
It cannot detect the physical lid position, so keeping the Mac open remains the operator's responsibility.
The App is the supported Start path. Direct lifecycle scripts run with the same logged-in-user authority and are reserved for implementation, diagnosis, and hardware-free tests. The heartbeat coordinates liveness and heat handling; it does not authenticate a different local user or process security domain. The console check is evaluated before Start and does not replace machine-wide arbitration inside the external batt daemon. A user calling batt directly, a later account login, or daemon behavior outside this repository remains beyond this guard.

## Stop and recovery

Use the app's Stop button first. From the source checkout:

    ./scripts/battcycle stop
    ./scripts/battcycle status

If adapter state needs recovery:

    ./scripts/battcycle restore
    batt status

The engine normally runs a separate cleanup-mode shell before it exits. It receives an 18-second primary completion window followed by bounded TERM and KILL convergence checks. Exit 0 means that cleanup completed, independent of the engine's original result. A contained nonzero exit or timeout starts one fresh bounded independent cleanup attempt; only a second failure reaches the original engine's final idempotent fallback. A cleanup group that still cannot be contained blocks concurrent fallback and keeps the lock. Known PGIDs use direct process-group queries, while the known leader PID covers the brief `setsid()` startup window. The final status preserves the original engine failure, and fallback failure forces failure. `SIGKILL` cannot run an exit handler, so Stop and Restore obtain the token only from a genuinely busy lock, treat the unique current-EUID token-bearing workload marker as the recovery authority, terminate authenticated PGIDs, and then restore and verify adapter power. The state `stressPgid` remains supporting evidence and may be absent or stale. Ambiguous process identity is never signaled; adapter recovery is still attempted and the command reports failure. A forced group termination may return status 2 even after adapter recovery is verified; this preserves the fact that shutdown was abnormal.

Restore must report verified adapter power before you assume it is available. If recovery fails, stop the workloads, disconnect and reconnect the charger when safe, and follow the official batt recovery documentation. Keep monitoring the physical charging indicator.

For excessive heat, smoke, swelling, odor, or liquid:

1. Stop the run if the Mac is responsive.
2. Disconnect power when it is safe to do so.
3. Move away from combustible material without touching a swollen or leaking battery.
4. Follow local emergency guidance and Apple battery-service guidance.

## Testing policy

Automated tests must use temporary directories and mocked tools. Tests, builds, packaging, CI, and app launch must never:

- disable the real adapter
- start a real stress workload
- install or modify a daemon
- invoke sudo
- change system power settings

Hardware acceptance is a separate, supervised procedure and must be labeled explicitly.

## Health claims

BattCycle makes no promise to improve capacity, lifespan, calibration, or performance. Repeated cycling generally consumes battery life. Consult Apple documentation or a qualified technician for battery-health decisions.
