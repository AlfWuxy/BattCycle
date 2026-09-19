# Expanded battery workspace restoration

The first UI redesign used the published `a73be5d` baseline. It therefore showed only the cycle experiment, although a separate uncommitted workspace already contained monitoring, history, adapter controls and advice. The original workspace was preserved. This revision restores that expanded source and applies the native sidebar to the complete feature set.

The local source snapshot contains 73 changed/new source, test and documentation files, captured before UI integration. Its sorted inventory SHA-256 is `33d4ebaee5c33245472e7d39e88c8ff7a8300b889becdcb12291df0363c46bdf`. No personal history, runtime configuration, logs, build output, credentials or user-specific tool settings were copied into the repository.

## Feature parity

| Original capability | Restored entry point | Implementation retained |
| --- | --- | --- |
| Battery percentage, energy-flow direction and charging/discharging/idle/unknown states | 电池概览 | `BatterySnapshot`, `EnergyFlow`, `OverviewView`, `EnergyFlowView` |
| Battery net power; physical adapter connection versus system using adapter; charging state | 电池概览 | `PowerMetrics`, `MetricRow`; independent source/availability labels |
| Adapter output/rated/negotiated watts, system watts, charging limits when genuinely provided | 电池概览 / 适配器控制 | Unsupported values stay unavailable; limits remain read-only |
| Thermal state, engine phase, last/next sample and data-trust/conflict state | 电池概览 | `SnapshotTick`, `DataTrust`, controller sampling state |
| 15m / 1h / 6h / 24h / 7d / 30d / custom history ranges | 曲线与历史 | `HistoryRange`, custom date bounds and full-range query |
| Battery and power charts, hover inspection, events and gap bands | 曲线与历史 | `HistoryView`, `HistoryQuery`; missing readings do not become zero |
| Energy in/out/net, mean and peak power, adapter/battery durations, completeness | 曲线与历史 | Full raw-sample energy derivation, explicitly labelled estimates |
| Pause/resume recording and CSV export | 曲线与历史 / 设置与诊断 | Recording independent of cycling; both exports use the full selected range |
| Standalone timed adapter suspend/resume | 适配器控制 | 1–600 seconds, presets, confirmation, deadline, command feedback and recovery state |
| Cycle thresholds, deadline, workload settings and default reset | 循环实验 | Six-key cycle configuration, minimum interval/24-hour bounds and Start confirmation |
| Local rule-based suggestions with facts, rule, confidence and actions | 使用建议 | `AdviceEngine`, current findings and insufficient-data state; no hardware actions |
| History interval presets/custom value and retention | 设置与诊断 | `MonitorSettings`, `RecordingController`, `SamplingPolicy`; independent of safety polling |
| Count/size diagnostics, confirmed clear history, monitor defaults | 设置与诊断 | JSONL history and sidecar; cycle config, monitoring config and logs are not deleted |
| Three-clock diagnostics, capability matrix, environment checks and logs | 设置与诊断 | `CapabilityInventory`, controller/service probes, local path display |
| Stop and Restore, including queued restoration | Persistent bottom controls and menu bar | `canStop` / `canRequestRestore`, not the older busy-only gating |
| Close/reopen behavior, active-cycle exit guard and sleep/wake handling | Native app lifecycle | Original expanded `BattCycleApp` lifecycle and common-mode timers |

## Deliberate integration changes

- The original five top-level tabs become six native sidebar sections. Cycle configuration is separated from standalone adapter control; no original capability is removed by that split.
- The previous redesign's `BatteryOverview` and `ActivityView` are superseded by the expanded overview and diagnostics views. Their visible functions remain accessible.
- The Settings CSV button uses the same full-range exporter as History, replacing its old chart-sample-only export.
- Recovery-enable prerequisites, ambiguous-disable compensation, Start/control locking, and streamed energy calculations receive targeted corrections and tests during restoration.
- The command launcher preserves Foundation-created isolated process groups; actual Swift runner regression executes only in GitHub CI, using harmless subprocesses.
- The original historical delivery/test-count notes are not republished as current proof. The existing packaging extended-attribute race was reproduced during the final release build. Its source-workspace non-`.app` signing stage is therefore restored separately, with metadata-only retries capped at two; unrelated signing failures still stop immediately. Package/signature/rollback checks validate the result.

## Evidence boundary

See [UI_VALIDATION.md](UI_VALIDATION.md) for the final commands, results and actual native view captures. Synthetic state renders and hardware-free tests do not prove actual device recovery, adapter behavior or native mouse/keyboard interactions. The app is not installed over the original workspace, and this PR does not merge or deploy itself.
