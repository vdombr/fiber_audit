# Static rule catalog

## Rule summary

| Rule | High-level concern |
|---|---|
| FA1001 | Subprocess lifecycle operations |
| FA1002 | Thread join/value waits |
| FA1003 | Synchronization primitives |
| FA1004 | Thread current state and true Thread variables |
| FA1005 | `IO.select` |
| FA1006 | Direct socket constructors |
| FA1007 | Net::HTTP in request contexts |
| FA1008 | Explicit blocking Fiber contexts |

Use `fiber-audit list-rules` for installed targets and `fiber-audit explain <RULE_ID>` for exact targets and remediation checks.

## Rule details

### FA1001 — Subprocess lifecycle operations

Flags configured Kernel, Open3, IO, Process, and Process::Status subprocess creation, replacement, waiting, detach, and stream operations. These are hypotheses about process coordination.

### FA1002 — Thread join/value waits

Flags `Thread#join` and `Thread#value`, which may require scheduler coordination while waiting for another thread.

### FA1003 — Synchronization primitives

Flags Mutex, ConditionVariable, Monitor, and MonitorMixin synchronization methods. Synchronization evidence does not imply deadlock or scheduler harm.

### FA1004 — Thread current state

Flags true `Thread#thread_variable_get` and `Thread#thread_variable_set` access. Fiber-local `Thread.current[]` APIs are distinct and are not this rule's target.

### FA1005 — IO.select

Flags `IO.select` and `Kernel.select`, whose waiting behavior may require scheduler cooperation. Timeout applicability is runtime evidence, not a causality claim.

### FA1006 — Direct socket constructors

Flags direct TCP, UDP, UNIX, Socket, IPSocket, and server constructors. Constructor inventory is distinct from address resolution or network endpoint setup.

### FA1007 — Net::HTTP in request contexts

Flags selected Net::HTTP and URI/OpenURI request operations in request-like execution contexts. Context raises attention, not certainty about scheduler impact.

### FA1008 — Blocking Fiber contexts

Flags `Fiber.new(blocking: true)` and `Fiber.blocking` regions. A lexically nested wait-capable operation adds advisory evidence depth; it does not prove execution or causality.

## Canonical operations

Rules and runtime probes share canonical operation vocabulary. Relevant operation strings include `block`, `kernel_sleep`, `io_wait`, `io_select`, `process_wait`, and `address_resolve`. Semantic metadata distinguishes `wait_possible` and `inventory_only` from scheduler capability requirements; these values do not themselves raise severity or imply causality.

## Keeping local docs in sync

When targets or semantics change, update the canonical vocabulary and the rule implementation together, then verify `fiber-audit list-rules` and `fiber-audit explain <RULE_ID>`. See [static analysis](static-analysis.md), [command reference](static-command.md), and [static output](static-output.md).
