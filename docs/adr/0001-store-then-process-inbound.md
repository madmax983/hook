# ADR 0001: Store, Then Process Inbound Events

Status: accepted. Date: 2026-10-18.

## Context

A provider calls a Site as the guest user. The provider wants a 2xx before its timeout ends. The guest user has few permissions. Work in the guest transaction is slow and unsafe.

## Decision

- The REST class verifies the request and inserts `Hook_Inbound_Event__c`. A unique `Dedup_Key__c` stops duplicates.
- It publishes `Hook_Inbound__e` with "publish after commit". The event holds only the record Id.
- `HookInboundTrigger` runs as the Automated Process user. It calls the handler for each event in its own savepoint.
- The trigger processes at most 20 events (`HookInboundDispatcher.chunkSize`). It stops early when half of a limit is used. It sets a resume checkpoint for the remainder.
- The record is the source of truth. `Dispatched_At__c` holds the last publish time. `HookSweep` publishes again for due `Retrying` rows, for rows whose publish failed, and for rows with no result 5 minutes after a dispatch. Such a lost dispatch counts as an attempt.
- For a retry of 10 minutes or less, `HookInboundRetryJob` publishes the row after the delay.

## Consequences

- Delivery to the handler is at least once. A handler must be idempotent. `HookInboundEvent.dedupKey` helps.
- Each request uses one platform event allocation.
- Callouts are not allowed in the trigger. A handler that must call out enqueues a Queueable or uses the Revenant handler.
