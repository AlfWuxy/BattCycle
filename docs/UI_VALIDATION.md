# Native UI validation

Validated on 2026-09-05. **UI: VERIFIED WITH MOCKS. Hardware: HOLD (not exercised).**

The redesign changes the SwiftUI presentation and native window/menu labels. The engine controller, batt service, battery capture, configuration validation, and runtime scripts are unchanged. Start still requires confirmation and the existing environment/thermal/busy gates. Stop, Restore Adapter, keyboard shortcuts, and the active-engine quit guard remain available. Plan edits are disabled while running or busy; the overview shows the active engine's recorded thresholds and deadline.

Unavailable battery snapshots and ambiguous zero-power readings display `—`. Power remains signed **battery-side** power. No capacity, cycle-health, exact-temperature, or hardware recovery result is inferred from the display.

## Reproduce the passive preview

```bash
./script/preview_ui.sh --state ready
./script/preview_ui.sh --state running --dark
./script/preview_ui.sh --state empty --width 820 --height 640
./script/preview_ui.sh --state error --width 820 --height 640
./script/preview_ui.sh --state ready --section plan
./script/preview_ui.sh --state ready --section activity --dark
```

The script builds a separate `dist/BattCycleUIPreview.app` using the real view files and an in-memory fixture controller. It does **not** compile the real `EngineController` or `BattService` into the preview. It does not read live configuration, poll hardware, write guardian state, inspect services, or run an experiment. Preview buttons only produce clearly labelled in-memory feedback. Close the preview window/app after inspection.

For native PNG capture, add `--output /absolute/path/to/existing-directory/image.png`. Captures use AppKit's native view rendering at the current screen scale, with the active-window control appearance. They show content rather than the title bar. The `ready`, `running`, `busy`, and `error` states are synthetic; `empty` deliberately supplies no battery or environment reading. The scheduled time uses the next local 07:00.

## Native render checks

| Surface | Evidence | Observed result |
| --- | --- | --- |
| Overview, Light | [Overview](screenshots/overview-light.png) | Battery hierarchy, range, deadline, environment and persistent controls render. |
| Cycle Plan, Light | [Plan](screenshots/plan-light.png) | Threshold steppers, date field and load disclosure render. |
| Running, Dark | [Running](screenshots/overview-running-dark.png) | Signed negative battery-side watts, running badge and enabled Stop render. |
| Status & Logs, Dark | [Activity](screenshots/activity-dark.png) | Environment, thermal-pressure text and log entry point render. |
| No readings, 820 × 640 | [Unavailable](screenshots/overview-empty-narrow.png) | Unknown values remain `—`; Start is disabled; Restore stays reachable. |
| Error, 820 × 640 | [Feedback](screenshots/feedback-narrow.png) | Error feedback stays above the persistent controls without clipping the actions. |
| Plan, 820 × 640 | [Narrow plan](screenshots/plan-narrow.png) | Steppers and date fields fit; detail content scrolls independently of controls. |

The main window defaults to 1040 × 820 content points; the view minimum is 820 × 640. Scrolling is expected at smaller heights. Light/Dark rendering was checked on the available macOS host; macOS 14 compatibility is checked by the package deployment target and compilation, not by running a macOS 14 machine. VoiceOver and reduced-transparency settings have not been manually exercised. Native interactive clicks remain unverified: the UI automation reader timed out twice while the preview app was still listed as running. The attempts stopped at that boundary; no app crash or successful click was inferred. Publication was approved using the build, mock-test, static-review, and native-render evidence above.

## Build and regression checks

- `swift build` and `swift build --configuration release`: passed.
- `swift test`: 9 tests passed.
- `/usr/bin/python3 -m unittest discover -s Tests/Scripts -p 'test_*.py'`: 44 tests passed.
- `/bin/zsh Tests/Scripts/test_shell_mocks.sh`: `shell mocks: ok`.
- `/bin/zsh packaging/package_app.sh`: app and clean ZIP extraction signature checks passed.
- `/bin/zsh Tests/Scripts/test_packaging_rollback.sh`: `packaging rollback: ok`.
- Shell syntax, Python compilation, packaging plist, forbidden privilege-pattern checks, and public-tree scan: passed.

The initial restricted-shell run could not start the mock workload marker. The same unmodified shell suite passed under the normal macOS process environment. It only used temporary mock commands; no real adapter operation or stress workload was run. These checks do not establish hardware acceptance.
