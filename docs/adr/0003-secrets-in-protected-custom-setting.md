# ADR 0003: Secrets in a Protected Custom Setting

Status: accepted. Date: 2026-10-18.

## Context

Apex must read the signing secret. Named Credentials do not give a secret value to Apex. Custom Metadata records go into source control and deploys.

## Decision

- Keep secrets in the protected list Custom Setting `Hook_Secret__c`. The record name is the secret name.
- Fields: `Value__c`, `Previous_Value__c`, `Previous_Expires_At__c`.
- `Hook.rotateSecret` moves the current value to the previous value with an expiry. Inbound accepts both. Outbound signs with both.
- Endpoint and subscription records refer to a secret by name.

## Consequences

- A deploy does not move secrets. Set them in each org (Setup or `Hook.setSecret`).
- In a managed package the setting is protected. In an unmanaged deploy, admins with "View All Custom Settings" can read it.
