# Runtime watchdog and liveness evidence

## Evidence, not proof

FiberAudit does not prove fiber safety, scheduler harm, causality, deadlock, or runtime coverage. Temporal overlap is evidence of co-occurrence, not proof of causality. Long-active operations are not scheduler stalls, deadlocks, or causal diagnoses. Absence of watchdog or liveness events is not proof that a path was safe or covered.

## Scheduler observation

In explicit runtime mode, `SchedulerObserver.activate(watchdog:)` uses narrow hooks around `Fiber.set_scheduler` and scheduler `close`. It observes scheduler ownership without broad tracing; runtime command setup belongs in [runtime auditing](runtime.md).

## Watchdog states

The watchdog reports one visible control state: `watchdog_disabled`, `watchdog_absent`, `watchdog_active`, or `watchdog_unsupported`. An active state means a per-scheduler/thread heartbeat was installed and polling can detect threshold crossings; absent and unsupported states are not silent success.

## Scheduler stall events

A threshold crossing emits bounded `scheduler_stall_started`, `scheduler_stall_frame`, `scheduler_stall_operation_overlap`, and `scheduler_stall_completed` evidence. Records can include stall and progress sequences, observed age, thresholds, frame counts, active-operation counts, truncation, operation sequence/start monotonic time, and classifier scalar measurements. Frames are redacted and project-relative where known.

The overlap event associates active operation sequences with a same-Thread stall in time. It is not a scheduler-harm or causality verdict.

## Active-operation overlap

Targeted operations register in a bounded active-operation registry. A stall may overlap those registrations even when ordinary events were sampled out. Control evidence bypasses random sampling but remains subject to rate, record-size, event, and session budgets.

## Operation liveness monitor

`OperationLivenessMonitor` is lifecycle-owned and independent of watchdog state. It reports `operation_liveness_active`, `operation_liveness_disabled`, and `operation_liveness_unsupported`. When an observed operation remains active for strictly beyond its threshold it emits `operation_long_active_started`; completion emits `operation_long_active_completed`.

The monitor emits at most ten starts per poll, uses bounded snapshots, and can complete an entry when it disappears from the registry. Shutdown completion records `operation_finished: false`; ordinary removal records true. Long-active evidence does not diagnose a stall or deadlock.

## Bounds, privacy, and blind spots

Drops, snapshot truncation, internal errors, and unsupported states remain visible. Runtime values are capture-time allowlisted; frames pass through redaction and omit unsafe or sentinel locations. Locations remain project-relative or unknown. Native work that retains Ruby's GVL can prevent both heartbeat and watchdog threads from running. This is a watchdog blind spot.

## Related runtime evidence

See [runtime activation and sessions](runtime.md), [synchronization graph evidence](runtime-synchronization-graph.md), and [process progress evidence](runtime-process-progress.md).
