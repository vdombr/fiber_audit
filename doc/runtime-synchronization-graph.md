# Runtime synchronization graph evidence

## What it is

The synchronization graph is opt-in, bounded, process-local runtime evidence. It is disabled by default (`enabled: false`). It records narrow ownership and wait transitions using opaque IDs, not object contents or application values.

## Enabling it

Configure the existing `runtime.synchronization_graph` policy:

```yaml
runtime:
  synchronization_graph:
    enabled: true
    max_identities: 4096
    max_resources: 2048
    max_wait_edges: 2048
    max_cycle_depth: 64
```

The graph is activated only by the explicit runtime command; requiring the gem does not start it.

## Identities and edges

Actors and resources receive bounded, session-local opaque IDs. Observations may record ownership, recursive ownership depth, wait edges, and whether ownership or a resource is known. IDs do not encode object contents. `sync_actor_id`, `sync_resource_id`, and `graph_truncated` are base measurements.

## Event lifecycle

| Group | Events |
|---|---|
| State | `sync_graph_active`, `sync_graph_disabled`, `sync_graph_unsupported`, `sync_graph_failed`, `sync_graph_stopped` |
| Lifecycle | `sync_wait_started`, `sync_wait_completed`, `sync_acquired`, `sync_released` |
| Cycle and bounds | `sync_cycle_candidate`, `sync_graph_truncated` |

## Cycle candidates

A `sync_cycle_candidate` event records bounded `cycle_sequence`, `cycle_actor_count`, and `cycle_edge_count`. It means the observed bounded graph contained a cycle candidate. It is not proof of deadlock, causality, scheduler harm, progress failure, or fiber safety. Absence of graph events is not proof that a path was safe or unexecuted.

## Bounds and truncation

The graph exposes `identity_count`, `resource_count`, `wait_edge_count`, `max_identities`, `max_resources`, `max_wait_edges`, and `max_cycle_depth`. When a limit is reached, `graph_truncated` and `sync_graph_truncated` make the loss of graph depth or breadth visible.

## Operations covered

The canonical operation strings come from `FiberAudit::OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS`; this page does not create a separate taxonomy:

- `Mutex#lock`, `Mutex#synchronize`, `Mutex#try_lock`, `Mutex#unlock`
- `ConditionVariable#wait`, `ConditionVariable#signal`, `ConditionVariable#broadcast`
- `Monitor#enter`, `Monitor#synchronize`, `Monitor#try_enter`, `Monitor#exit`
- `MonitorMixin#mon_enter`, `MonitorMixin#mon_synchronize`, `MonitorMixin#mon_try_enter`, `MonitorMixin#mon_exit`
- `MonitorMixin::ConditionVariable#wait`, `MonitorMixin::ConditionVariable#signal`, `MonitorMixin::ConditionVariable#broadcast`

## Privacy and interpretation limits

Graph evidence retains only allowlisted scalar measurements and opaque IDs. It must not include commands, command arguments, URLs, hosts, ports, headers, bodies, payloads, return values, exception messages, environment secrets, object contents, thread-local keys or values, or absolute paths outside allowed project-relative representation.

Wait/ownership overlap and cycle candidates are bounded observations, not proof of deadlock, causality, scheduler harm, progress failure, or fiber safety. Runtime observations prove execution only. See [runtime auditing](runtime.md) and [watchdog/liveness evidence](runtime-watchdog-and-liveness.md).
