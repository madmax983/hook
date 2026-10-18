# Hook Global API

This page lists each `global` type and member. Other code is `public` and can change.

## Policy

- Do not remove or change a member in the manifest after the first release.
- Do not add a method to a `global` interface. Add a new interface.
- A new `@InvocableVariable` must be optional.
- Change the manifest in the same commit as the code. `npm run test:api` fails when they are different.

## Format

- `global <kind> <Type>`: a type, with `extends` and `implements`.
- `[static] <Type>.<method>(<parameter types>): <return type>`: a method.
- `new <Type>(<parameter types>)`: a constructor.
- `<Type>.<name>: <type> { get }`: a read-only property.
- `<Type>.<name>: <type>`: a field.
- Interface methods are `global` because the interface is `global`.
- Annotations show with their compatibility arguments.

## Manifest

```hook-global-api
# Facade
global class Hook
static Hook.send(String, Object): String
static Hook.send(String, Object, String): String
static Hook.send(List<HookEvent>): List<String>
static Hook.redeliver(Set<Id>): void
static Hook.replayInbound(Set<Id>): void
static Hook.setSecret(String, String): void
static Hook.rotateSecret(String, Integer): String
static Hook.scheduleSweep(): void
static Hook.unscheduleSweep(): void
global class HookEvent
new HookEvent(String, Object)
HookEvent.eventType: String { get }
HookEvent.payload: Object { get }
HookEvent.eventId: String { get }
HookEvent.withId(String): HookEvent
global class HookException extends Exception

# Inbound
global interface HookInboundHandler
HookInboundHandler.handle(HookInboundEvent): void
global interface HookVerifier
HookVerifier.verify(HookRequest, List<String>): HookVerification
global interface HookHandshake
HookHandshake.respond(HookRequest, List<String>): HookResponse
global class HookInboundEvent
HookInboundEvent.recordId: Id { get }
HookInboundEvent.endpoint: String { get }
HookInboundEvent.eventId: String { get }
HookInboundEvent.eventType: String { get }
HookInboundEvent.dedupKey: String { get }
HookInboundEvent.body: String { get }
HookInboundEvent.attempt: Integer { get }
HookInboundEvent.config: String { get }
HookInboundEvent.header(String): String
HookInboundEvent.json(): Object
HookInboundEvent.valueAt(String): Object
global class HookRequest
HookRequest.method: String { get }
HookRequest.endpoint: String { get }
HookRequest.body: String { get }
HookRequest.bodyBlob: Blob { get }
HookRequest.remoteAddress: String { get }
HookRequest.header(String): String
HookRequest.param(String): String
global class HookVerification
static HookVerification.valid(String, String): HookVerification
static HookVerification.invalid(String): HookVerification
HookVerification.isValid: Boolean { get }
HookVerification.reason: String { get }
HookVerification.eventId: String { get }
HookVerification.eventType: String { get }
global class HookResponse
new HookResponse(Integer, String, String)
HookResponse.statusCode: Integer { get }
HookResponse.body: String { get }
HookResponse.contentType: String { get }
@RestResource global class HookInboundResource
@HttpPost static HookInboundResource.doPost(): void
@HttpGet static HookInboundResource.doGet(): void

# Outbound
global interface HookChannel
HookChannel.dispatch(List<Id>): void
global class HookDelivery
static HookDelivery.prepare(Id): HookDelivery.Attempt
global class HookDelivery.Attempt
HookDelivery.Attempt.deliveryId: Id { get }
HookDelivery.Attempt.attempts: Integer { get }
HookDelivery.Attempt.maxAttempts: Integer { get }
HookDelivery.Attempt.isDelivered(): Boolean
HookDelivery.Attempt.send(): HookDelivery.Outcome
HookDelivery.Attempt.record(Datetime): void
global class HookDelivery.Outcome
HookDelivery.Outcome.kind: String { get }
HookDelivery.Outcome.statusCode: Integer { get }
HookDelivery.Outcome.retryAfterSeconds: Integer { get }
HookDelivery.Outcome.error: String { get }
HookDelivery.Outcome.isDelivered(): Boolean
HookDelivery.Outcome.isRetryable(): Boolean

# Flow
global class HookSendAction
@InvocableMethod static HookSendAction.send(List<HookSendAction.Request>): List<HookSendAction.Result>
global class HookSendAction.Request
@InvocableVariable(required=true) HookSendAction.Request.eventType: String
@InvocableVariable HookSendAction.Request.payloadJson: String
@InvocableVariable HookSendAction.Request.eventId: String
global class HookSendAction.Result
@InvocableVariable HookSendAction.Result.eventId: String
global class HookReplayAction
@InvocableMethod static HookReplayAction.replay(List<Id>): void
```

## Notes

- `HookDelivery.Outcome.kind` is one of `DELIVERED`, `RETRY`, `GONE`, `CONFIG`, `PAUSED`. `PAUSED`: the subscription is not active.
- `HookDelivery.Attempt.record(nextAttemptAt)`: call it after `send()`. `DELIVERED` sets `Delivered`. `RETRY` with a time sets `Retrying`, and with null sets `Failed`. `GONE` and `CONFIG` set `Failed`. `PAUSED` sets `Pending` and counts no attempt. With no `send()`, it does nothing. It writes nothing when another job or a redelivery took the row after `prepare()`.
- `HookFlowHandler`, `HookQueueChannel` and the Revenant adapter classes are `public`. Configuration names them. Code does not call them.
