# Expanded native workspace validation

Restoration evidence recorded on 2026-09-06. **UI and control logic use mocks. Hardware/native clicks are not exercised.** Final command-launch verification runs in GitHub CI; the check attached to the current PR revision is authoritative.

This revision restores the expanded monitoring/history/adapter/advice implementation and presents it in six native sidebar sections. Controller, core and runtime changes are included; this is not a presentation-only diff. See [the restoration inventory](FEATURE_RESTORATION.md) for feature parity and the exact source snapshot identifier.

## Reproduce the passive preview

```bash
./script/preview_ui.sh --state ready --section overview
./script/preview_ui.sh --state ready --section history --height 1000
./script/preview_ui.sh --state ready --section adapter
./script/preview_ui.sh --state ready --section cycle
./script/preview_ui.sh --state ready --section advice --dark
./script/preview_ui.sh --state ready --section settings
./script/preview_ui.sh --state running --dark
./script/preview_ui.sh --state empty --width 820 --height 640
./script/preview_ui.sh --state error --width 820 --height 640
```

Add `--output /absolute/path/to/existing-directory/image.png` for native PNG capture. The script builds a separate `dist/BattCycleUIPreview.app` from the real view files and an in-memory fixture controller. The preview executable does not link the real `EngineController` or `BattService`, read live configuration, poll hardware, write guardian state, inspect services, or run an experiment. Preview buttons only produce labelled in-memory feedback. Settings receives a unique nonexistent temporary history path instead of scanning real history.

The `ready`, `running`, `busy`, and `error` states are synthetic; `empty` supplies no battery/environment readings. AppKit renders the actual views at the current display scale; these captures show content rather than title bars. The snapshot-only environment flag freezes energy arrows for deterministic layer capture; normal app animation and system settings remain unchanged.

## Native render checks

| Surface | Evidence | Observed result |
| --- | --- | --- |
| Overview, Light | [Overview](screenshots/overview-light.png) | Six-section sidebar, battery/energy flow, source-labelled metrics and persistent recovery. |
| History, Light | [History](screenshots/history-light.png) | Battery and power charts, missing-data gap, distinct charge/discharge segments, zero line and events. |
| Adapter, Light | [Adapter](screenshots/adapter-light.png) | Timed control, duration presets, command feedback and read-only batt facts. |
| Cycle, Light | [Cycle](screenshots/plan-light.png) | Thresholds, stop time, workload configuration and dedicated Start action. |
| Advice, Dark | [Advice](screenshots/advice-dark.png) | Read-only findings, facts and insufficient-data treatment. |
| Settings, Light | [Settings](screenshots/settings-light.png) | Recording interval, retention, count/size, CSV/clear controls and three clocks. |
| Running, Dark | [Running](screenshots/overview-running-dark.png) | Battery-to-Mac flow, running state, enabled Stop and recovery. |
| No readings, 820 × 640 | [Unavailable](screenshots/overview-empty-narrow.png) | Unknown/not-provided values remain unavailable; no fabricated zero or false state. |
| Error, 820 × 640 | [Feedback](screenshots/feedback-narrow.png) | Adapter failure and recovery stay visible; bottom controls remain reachable. |
| Cycle, 820 × 640 | [Narrow cycle](screenshots/plan-narrow.png) | Date/threshold controls fit; detail scrolls independently of persistent actions. |

The default content size is 1120 × 860 points, with a minimum of 820 × 640. The history capture uses 1120 × 1000 to show both charts and their legend. Longer sections intentionally scroll. System fonts, native List/sidebar selection, form controls, semantic colours, keyboard shortcuts and destructive confirmations are preserved. Settings exports the full selected history range, matching History. Chart series identities prevent lines reconnecting across gaps.

## Recorded checks before the final launcher correction

- Linked debug build and release app packaging: passed on the integrated source.
- Core Swift suite: **275 executed, 274 passed, 1 skipped, 0 failures** (`BATTCYCLE_SKIP_PERF=1 swift test`). The skipped test is the original million-row synthetic JSONL chart-performance probe.
- Energy-targeted suite: **25/25 passed**, including one million lazily generated samples through the scalar accumulator, and a 5,001-row JSONL spike case exercising the same full-history estimator used by the app. The integration accumulator stores scalars (192 bytes in this build); this does not claim that the complete app uses constant memory.
- Python hardware-free tests: **50/50 passed** (`/usr/bin/python3 -m unittest discover -s Tests/Scripts -p 'test_*.py'`).
- Final shell mock suite: passed (`shell mocks: ok`).
- Package signature, clean ZIP extraction strict verification and atomic rollback: passed. A reproduced Finder-metadata signing race was corrected using the source workspace's temporary non-`.app` signing stage; metadata-specific retries are capped at two.
- Shell syntax, Python compilation, plist and privilege-boundary checks: passed. Exact Git-index public-content scan is checked before commit.

The runtime regressions cover missing timed-disable help on recovery, nonzero/timeout after disable has taken effect, delayed/unknown/failed status, restored-power verification, control-generation exclusion, and actual lock handoff including failed engine exec. Energy tests preserve zero-crossing integration, unknown readings, gaps and full raw-sample estimates independent of chart downsampling. Range selection invalidates old chart/energy/advice publications without discarding completed recording acknowledgements; clearing uses a separate recording generation.

These builds and tests ran before the request to stop local execution. After that request, local compilation, packaging and tests stopped, and the leftover passive preview was closed. All final launcher, subprocess, regression, build and packaging checks run on the GitHub-hosted macOS runner. No real adapter command, load generator, installed app, service, system setting or original Desktop source was modified by the local checks.

## Final command-launch regression in CI

An exact-source temporary Swift harness exposed an existing launcher problem: Foundation's child can already lead its own process group, making an unconditional `setsid()` fail with `EPERM` before even `/bin/echo` runs. The launcher correction only accepts an already-isolated group when the process is its own group leader; other failures remain errors. The PID is preserved so Swift can terminate the same command group.

The final CI pipeline exercises ordinary child launch, already-group-leader launch, refusal of unproven isolation, and the real `BattService.swift` command runner with harmless echo and a temporary timeout fixture. The latter checks that a surviving child is contained even if its leader exits first. No service power-control method is called. The CI harness refuses to run outside GitHub Actions.

Use the [current PR checks](https://github.com/AlfWuxy/BattCycle/pull/1/checks) for final-revision pass/fail evidence. Earlier local counts above do not substitute for those checks.

## Remaining acceptance limits

Actual native clicks remain unverified: the previous UI automation reader timed out twice while the passive preview was listed as running, and those attempts stopped. The user authorized PR publication using build, mock-test, static-review and native-render evidence; no click success or app crash is inferred. Real battery/adapter/stress recovery remains untested. macOS 14 compatibility is checked through deployment target and compilation, not a macOS 14 device; VoiceOver and reduced-transparency settings were not manually exercised. The PR does not install, merge or release the app.
