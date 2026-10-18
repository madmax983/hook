# Hook

Inbound and outbound webhooks for Salesforce. An optional adapter makes each webhook a durable [Revenant](https://github.com/madmax983/revenant) workflow.

- **Inbound:** one public endpoint, `/services/apexrest/hook/{name}`. Hook verifies the signature over the raw bytes, stops replays and duplicates, stores the event, and returns 200 at once. A handler processes the event after commit, as the Automated Process user, with retries.
- **Outbound:** `Hook.send('order.paid', payload)`. Hook writes an outbox row for each matching subscription. A job sends a signed [Standard Webhooks](https://www.standardwebhooks.com) request with backoff, `Retry-After`, auto-disable and a delivery log. It is safe in a trigger.

Design: [docs/plans/2026-10-18-hook-design.md](docs/plans/2026-10-18-hook-design.md). API: [docs/api.md](docs/api.md). Decisions: [docs/adr](docs/adr).

## Install

```sh
git clone --recurse-submodules https://github.com/madmax983/hook.git
cd hook
sf project deploy start --source-dir force-app
sf org assign permset --name Hook_Admin
```

The Revenant adapter needs Revenant in the org. To deploy all of it: `sf project deploy start`.

Then start the sweep one time. It finds due retries, lost jobs and old rows.

```apex
Hook.scheduleSweep();
```

## Inbound Webhooks

### 1. Make a Site

1. In Setup, open **Sites**. Make a Site. Make it active.
2. Open **Public Access Settings** of the Site. Open the guest user. Assign the permission set **Hook_Guest**.
3. The endpoint URL is `https://<site domain>/services/apexrest/hook/<name>`.

`Hook_Guest` gives only the class `HookInboundResource`, and read and create access on `Hook_Inbound__e`. A guest cannot use an endpoint with the scheme `NONE`.

### 2. Set the secret

Give the provider signing secret to Hook. Run this in Anonymous Apex:

```apex
Hook.setSecret('stripe_live', 'whsec_...');
```

Secrets are in the protected Custom Setting `Hook_Secret__c`. A deploy does not move them.

### 3. Add an endpoint

Make a `Hook_Endpoint__mdt` record. The record name is the last part of the URL.

| Field | Example | Use |
|-------|---------|-----|
| `Active__c` | true | False returns 404 |
| `Scheme__c` | `STRIPE` | See the table below |
| `Secret_Names__c` | `stripe_live` | Names separated by commas |
| `Handler_Class__c` | `PaymentHandler` | A `HookInboundHandler` |
| `Handler_Config__c` | `{"flow":"Paid"}` | JSON for the handler |
| `Tolerance_Seconds__c` | 300 | Largest age of a signed timestamp |
| `Max_Attempts__c` | 5 | Handler attempts. Blank uses the org default |

| Scheme | Headers | Signed data |
|--------|---------|-------------|
| `STANDARD_WEBHOOKS` | `webhook-id`, `webhook-timestamp`, `webhook-signature` (or `svix-*`) | `id.timestamp.body`, key is base64 after `whsec_` |
| `STRIPE` | `Stripe-Signature` | `t.body` |
| `GITHUB` | `X-Hub-Signature-256` | body |
| `SLACK` | `X-Slack-Signature`, `X-Slack-Request-Timestamp` | `v0:timestamp:body`. Hook answers `url_verification` |
| `SHOPIFY` | `X-Shopify-Hmac-Sha256` | body, base64 |
| `HMAC_SHA256` | `Signature_Header__c` | body. Set `Signature_Prefix__c` and `Signature_Encoding__c` (`hex` or `base64`) |
| `TOKEN` | `Signature_Header__c` (default `Authorization`) | none. The header is equal to the secret after `Signature_Prefix__c` |
| `NONE` | none | none. Use only for an authenticated caller |

For another provider, set `Verifier_Class__c` to a class that implements `HookVerifier`.

When the scheme gives no event Id, set `Event_Id_Header__c` or `Event_Id_Path__c` (for example `data.id`). Else Hook uses the SHA-256 of the body. Do the same for the type with `Event_Type_Header__c` or `Event_Type_Path__c`.

The dedup key uses only signed data: the Id of `STANDARD_WEBHOOKS`, `STRIPE` or `SLACK`, else `Event_Id_Path__c`, else the body hash. An Id from an unsigned header (for example `X-GitHub-Delivery`) shows in `Event_Id__c`, but a replay with a new header Id is still a duplicate. Hook does not store `Authorization`, `Cookie`, `Proxy-Authorization`, `X-Api-Key` or the `Signature_Header__c` header.

### 4. Write a handler

```apex
public class PaymentHandler implements HookInboundHandler {
  public void handle(HookInboundEvent event) {
    String orderId = (String) event.valueAt('data.object.metadata.order_id');
    // Do the work. Throw to retry. Hook rolls back the DML of a failed call.
  }
}
```

- Hook calls the handler after commit, as the Automated Process user.
- Hook can call a handler again. Make it idempotent. Use `event.dedupKey`.
- Do not call out in a handler. A platform event trigger cannot. Enqueue a job, or use the Revenant handler.
- No code: set `Handler_Class__c` to `HookFlowHandler` and `Handler_Config__c` to `{"flow": "My_Flow"}`. The Flow gets `endpoint`, `eventId`, `eventType`, `body` and `recordId`.

### Responses

| Status | When |
|--------|------|
| 200 `accepted` | Hook stored the event |
| 200 `duplicate` | Hook has the event already |
| 401 | The signature or the timestamp is not valid |
| 404 | No active endpoint has the name |
| 405 | A GET with no handshake |
| 413 | The body is longer than 131,072 characters |
| 400 | The body is not UTF-8 |
| 500 | An unexpected error. The provider retries |

### States

`Hook_Inbound_Event__c.Status__c`: `Pending`, then `Processed`. A handler error sets `Retrying` with backoff. After the last attempt, or for a bad handler class, it is `Failed`. A dispatch that stops with no result (for example a limit error) counts as an attempt when the sweep finds it. To process again: `Hook.replayInbound(ids)` or the Flow action **Replay Webhook**.

One trigger run stops after 20 events or when half of a limit is used. The platform sends the rest in a new run.

## Outbound Webhooks

### 1. Add a subscription

```apex
Hook_Subscription__c sub = new Hook_Subscription__c(
  Name = 'Acme',
  Endpoint__c = 'callout:Acme_Webhooks/hooks',
  Event_Types__c = 'order.*, invoice.paid',
  Secret_Name__c = 'acme'
);
insert sub;
String secret = Hook.rotateSecret('acme', 0); // Give this to Acme.
```

- `Endpoint__c` must start with `https://` or `callout:`. A Named Credential is best. For a URL, add a Remote Site Setting.
- `Event_Types__c`: `*` for all, an exact type, or a prefix such as `order.*`. The compare ignores case.
- `Channel__c`: blank uses the built-in queue. `HookRevenantChannel` uses Revenant.

### 2. Send

```apex
Hook.send('order.paid', new Map<String, Object>{ 'orderId' => order.Id });
Hook.send('order.paid', payload, 'evt_' + order.Id); // The same Id sends one time.
```

In Flow, use the action **Send Webhook**. It takes `eventType`, `payloadJson` and `eventId`.

The request:

```http
POST /hooks HTTP/1.1
Content-Type: application/json
webhook-id: msg_2b1f...
webhook-timestamp: 1700000000
webhook-signature: v1,<base64 HMAC-SHA256 of "id.timestamp.body">

{"id":"msg_2b1f...","type":"order.paid","timestamp":"2023-11-14T22:13:20.000Z","data":{"orderId":"801..."}}
```

The subscriber can verify it with any Standard Webhooks library. Deduplicate on `webhook-id`.

### Delivery rules

| Response | Result |
|----------|--------|
| 2xx | `Delivered`. The failure count goes to 0 |
| 429 or 503 with `Retry-After` | `Retrying` after that time, at most `Max_Delay_Seconds__c` (default 6 h) |
| Other non-2xx, timeout, `CalloutException` | `Retrying` after `60 s * 2^(attempt-1)` +/- 20%, at most `Max_Delay_Seconds__c` (default 6 h) |
| The last attempt fails | `Failed` |
| 410 | `Failed`. The subscription is disabled |
| No secret, or a secret that Hook cannot use | `Failed` with the reason |
| Inactive subscription | `Pending`. No attempt counts. The row waits |

After `Disable_After_Failures__c` failed attempts in a row (default 50), Hook disables the subscription. Rows of an inactive subscription wait. Make the subscription active again, and the queue sends them. To send again: `Hook.redeliver(ids)` or **Replay Webhook**.

Hook writes a result only when its job still owns the row. A redelivery during a send wins. Hook changes `Active__c` only to disable a subscription.

### Secret rotation

`Hook.rotateSecret('acme', 24)` makes a new secret. For 24 hours Hook signs with the new and the old secret. Inbound endpoints accept both. To revoke a leaked secret at once, use `Hook.setSecret`: it removes the old value.

## Settings

`Hook_Setting__mdt` record `Default`:

| Field | Default | Use |
|-------|---------|-----|
| `Batch_Size__c` | 10 | Deliveries for each job. Hook keeps `batch * timeout` at or below 120 s |
| `Timeout_Ms__c` | 10000 | Callout timeout |
| `Max_Attempts__c` | 10 | Attempts for one delivery or one inbound event |
| `Base_Delay_Seconds__c` | 60 | First retry delay |
| `Max_Delay_Seconds__c` | 21600 | Largest retry delay |
| `Disable_After_Failures__c` | 50 | 0 is never |
| `Lease_Minutes__c` | 10 | Time a job owns a claimed row |
| `Retention_Days__c` | 30 | The sweep deletes `Delivered` and `Processed` rows after this |
| `Default_Channel__c` | blank | The channel for a subscription with no channel |

## Revenant Adapter

The folder `revenant-adapter` uses only the Hook and Revenant global APIs.

**Durable outbound.** Set `Hook_Subscription__c.Channel__c` to `HookRevenantChannel`. Each delivery starts the workflow `HookRevenantDelivery.DeliveryWorkflow`. Its one step is a `CalloutStep`:

- 2xx completes.
- 429 or 503 with `Retry-After` is a durable `sleep`.
- Other failures `retry` with backoff.
- The last attempt, 410 and a missing secret `fail`.
- An inactive subscription sets the row to `Pending` and fails the workflow. Redeliver after you make the subscription active again.
- A delivered row completes with no callout, so a re-run is safe.
- A redelivery cancels the workflow of the last generation when it still runs.
- Revenant owns the wait: 60 s, then doubled for each attempt. The Hook delay settings do not apply. `Next_Attempt_At__c` only shows the time.
- When Revenant cancels or fails the workflow on its side, the row can stay `Retrying`. Redeliver it.

**Durable inbound.** Set `Handler_Class__c` to `HookRevenantInboundHandler`:

```json
{"mode": "start", "workflow": "acme.OrderWorkflow", "keyPath": "data.object.id"}
{"mode": "signal", "signal": "PaymentReceived", "keyPath": "data.object.metadata.order_key"}
```

`start` uses `startOrGet`. The input holds `endpoint`, `eventId`, `eventType` and `payload`. With no `keyPath`, the key is the dedup key. A key that an instance of another workflow has is an error. `signal` uses the dedup key as the idempotency key. A signal to a key with no running workflow is an error, so Hook retries it. Hook changes a key longer than 200 characters to `sha256:` and its hash.

In a namespaced Revenant install, add the namespace to the Revenant types in the adapter (for example `rvn.WorkflowStep`).

## Limits

- Delivery is at least once in both directions. Order is not kept.
- Apex REST does not give the raw bytes of an `application/x-www-form-urlencoded` body. Hook cannot verify such a request (for example a Slack slash command). JSON providers work.
- Each inbound request uses one platform event.
- A body or payload can have at most 131,072 characters.
- The sweep runs every 15 minutes. A delayed job covers a retry of 10 minutes or less, in both directions. A longer retry waits for the sweep.
- A `callout:` endpoint can use any Named Credential in the org. Give `Hook_Admin` only to users who may use those credentials.

## Development

```sh
npm ci
npm test                          # vectors, API manifest, coverage script
bash scripts/apex-ls/fetch-apex-ls.sh
npm run check:apex-compile        # compile all Apex with no org
npm run format:check
sf code-analyzer run --workspace force-app --workspace revenant-adapter --rule-selector recommended --severity-threshold 2
```

Org tests run in `.github/workflows/apex-tests.yml` when the repository has the secret `DEVHUB_SFDX_AUTH_URL`. Add the label `run-org-tests` to a pull request. The job fails when the coverage of the Hook classes is below 85%.

## License

Apache-2.0.
