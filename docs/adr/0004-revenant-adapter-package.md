# ADR 0004: Revenant Adapter as a Separate Package Folder

Status: accepted. Date: 2026-10-18.

## Context

Revenant gives durable steps, sleep, retry, and audit. Many orgs do not have Revenant. The core must not need it.

## Decision

- The core (`force-app`) has no Revenant reference. It defines the `HookChannel` and `HookInboundHandler` extension points.
- The adapter (`revenant-adapter`) uses only the Revenant global API and the Hook global API.
- A subscription selects the adapter with `Channel__c = HookRevenantChannel`. An endpoint selects it with `Handler_Class__c = HookRevenantInboundHandler`.
- The repository holds Revenant as a submodule (`lib/revenant`) for the compile check and the org tests.

## Consequences

- Install the core alone, or the core, Revenant, and the adapter.
- In a namespaced Revenant install, add the namespace prefix to the Revenant types in the adapter.
