# ADR 0002: Outbound Outbox With Claim Token and Lease

Status: accepted. Date: 2026-10-18.

## Context

Apex blocks a callout after DML and in a trigger. Two jobs must not send the same row. A job can stop with an uncatchable limit error.

## Decision

- `Hook.send` inserts `Hook_Delivery__c` rows (the outbox) and calls the channel of each row.
- `HookQueueChannel` sets `In_Flight`, a claim token for the transaction, and a lease. It enqueues one `HookDispatchJob` for each transaction. The job runs only after commit.
- `HookDispatchJob` reads its rows by token, makes the callouts with no DML before them, then writes the results. Then it claims the next due rows with `FOR UPDATE` and chains a new job.
- A short retry (10 minutes or less) enqueues a delayed claim job. `HookSweep` claims longer retries and expired leases.

## Consequences

- Delivery is at least once. The receiver deduplicates on `webhook-id`.
- Order is not kept.
- Each send transaction uses one Queueable.
