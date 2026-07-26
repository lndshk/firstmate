---
name: ops-execution
description: Execute known operational runbooks—deploys, jobs, migrations, recoveries, validations, and other documented commands—with durable manifests and artifact-based proof. Use whenever a request has a known command or supported operational procedure and needs execution, monitoring, retry, or a definitive outcome.
---

# Operations Execution

Execute the runbook. Do not substitute research, advice, or progress prose for an operation with a documented command.

## 1. Commit the operation

Before saying work is underway, record a durable task with: owner, deliverable, acceptance predicate, deadline, and status.

Before running the command, create a durable operation manifest. Record:

```text
command:
expected_receipt:
expected_artifacts:
freshness_predicate:
timeout:
safe_retry_policy:
pass_predicate:
fail_predicate:
```

Use a runbook-supported command and retry only as the manifest permits. Set a deadline; do not leave an operation indefinitely pending.

## 2. Execute and prove

Run the documented command immediately. Capture its exit code, stderr, receipt, and artifact proof in the durable record.

Judge completion from the expected artifacts, process revision, and health/freshness predicate. A pane, prose, a live PID, or an agent assertion is never proof of completion.

Mark `passed` only when the pass predicate holds. Mark `failed` when the fail predicate holds. Attach the exact evidence to either result.

## 3. Handle exceptions

Never use `investigating` as a status by itself. It must name the exact failed command, its evidence, and the next supported command.

At the deadline, if no required receipt or artifact exists, mark the operation `stalled`. Surface the task, last useful action, evidence, and next action.

Do not create broad research or advisor work for a known runbook. Use an agent only to diagnose a concrete command failure or make a bounded repair; then return to the documented command.

## 4. Monitor deterministically

Poll mundane work with deterministic tooling and zero LLM tokens. Persist each poll result and evaluate the manifest predicates. Escalate only a terminal result, a deadline, or an actionable concrete failure.
