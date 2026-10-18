# Hook: Acceptance Criteria and Evidence

Status on 2026-10-18 at commit `a0e9c4a`. The criteria are in [the design](2026-10-18-hook-design.md), section 6.

## Gates that ran

| Gate | Result |
|------|--------|
| `npm run check:apex-compile` (core, Revenant, adapter) | 0 issues |
| `npm run check:apex-compile:core` (core only) | 0 issues |
| `npm test` (vectors, API manifest, coverage script, metadata) | 15 of 15 pass |
| `npm run format:check` | pass |
| Code Analyzer, `recommended`, severity 2 | 0 findings at High or worse |
| GitHub CI on the PR | green |
| Org Apex tests (`apex-tests.yml`) | **not run**: the repository has no `DEVHUB_SFDX_AUTH_URL` secret |

Test names below are `Class.method`. All test classes start with `Hook`. "Apex" means an Apex test that runs in the org workflow.

## Inbound

| AC | Implementation | Evidence |
|----|----------------|----------|
| AC-IN-1 Route `/hook/{name}`, 404 when unknown or inactive | `HookInboundResource`, `HookRequest.endpointFromUri`, `HookEndpoints.get` | Apex: `InboundTest.anUnknownOrInactiveEndpointGives404`, `endpointNameComesFromTheLastPathSegment`, `theRestResourceWritesTheResponse`, `anUnknownEndpointReadsNoRecord` |
| AC-IN-2 Eight schemes and a custom verifier | `HookVerifiers` | Apex: `VerifiersTest`, one or more tests for each scheme, `aCustomVerifierClassIsUsed`, `tokenUsesAuthorizationByDefault` |
| AC-IN-3 Sign the raw bytes | `HookSigner.concat`, verifiers sign `bodyBlob` | Apex: `VerifiersTest.theSignatureCoversTheRawBytes`, `SignerTest.concatKeepsTheBytes`, the unicode vector in `standardWebhooksAcceptsSvixHeadersAndAPreviousSecret` |
| AC-IN-4 Header names ignore case | `HookRequest` | Apex: `VerifiersTest.standardWebhooksAcceptsTheSpecVector` (mixed case), `InboundDispatcherTest.theHandlerGetsTheEventAndTheRowIsProcessed` |
| AC-IN-5 Timestamp tolerance, default 300 s | `HookVerifiers.timestampProblem` | Apex: `InboundTest.anOldTimestampGives401` (default, through `receive`), `VerifiersTest.stripeChecksTheV1SignatureAndTheTimestamp`, `aBadTimestampIsInvalidAndDoesNotThrow` |
| AC-IN-6 One row, duplicate gives 200 | `HookInbound.store`, unique `Dedup_Key__c` | Apex: `InboundTest.aDuplicateStoresNothing`, `aReplayWithANewUnsignedIdIsADuplicate`, `anUnsignedIdCannotBlockALaterEvent`, `aSignedIdIsTheDedupKey`; Node: `metadata.test.mjs` (unique, case-sensitive) |
| AC-IN-7 Publish after commit, handler runs, `Processed` | `Hook_Inbound__e` (PublishAfterCommit), `HookInboundTrigger`, `HookInboundDispatcher` | Apex: `InboundTest.aValidRequestStoresOneEventAndPublishes`; Node: `metadata.test.mjs` |
| AC-IN-8 Handler DML rolls back for one event only | savepoint in `HookInboundDispatcher.run` | Apex: `InboundDispatcherTest.aThrowingHandlerRollsBackItsDmlAndRetries` |
| AC-IN-9 Retry with backoff, then `Failed`; bad handler fails at once | `retryOrFail`, `HookInboundRetryJob`, `HookSweep.republishInbound` | Apex: `InboundDispatcherTest.theLastAttemptFailsTheRow`, `theEndpointMaxAttemptsWins`, `aMissingHandlerOrEndpointFailsAtOnce`, `SweepTest.aLostRetryCountsAnAttempt`, `aStalePendingRowWithNoAttemptsLeftFails` |
| AC-IN-10 413 above 131,072 characters, 400 for bad UTF-8 | `HookInbound.bodyProblem` | Apex: `InboundTest.aLargeBodyGives413AndBadUtf8Gives400`, `theBodyDecodesWhenARequestIsRead` |
| AC-IN-11 Slack challenge, handshakes, GET 405 | `HookVerifiers.Slack.respond`, `HookHandshake` | Apex: `InboundTest.slackUrlVerificationGivesTheChallenge`, `aGetUsesTheHandlerHandshakeOrGives405`, `aGetUsesTheVerifierHandshake` |
| AC-IN-12 Replay | `Hook.replayInbound` | Apex: `InboundDispatcherTest.replayInboundSetsPendingAndPublishes`, `ActionsTest.replayActionSplitsByRecordType` |
| AC-IN-13 Flow handler | `HookFlowHandler` | Apex: `ActionsTest.flowHandlerStartsTheConfiguredFlow`, `flowHandlerNeedsAFlowName`, `theDefaultLauncherStartsARealFlow` |
| AC-IN-14 Unexpected error gives 500 | `HookInbound.receive` | Apex: `InboundTest.anErrorGives500AndRollsBack`, `anErrorAfterDmlRollsBack` |

## Outbound

| AC | Implementation | Evidence |
|----|----------------|----------|
| AC-OUT-1 One row for each match, no callout in the caller | `HookOutbound.send`, `matches` | Apex: `OutboundTest.sendMakesOneDeliveryForEachMatchingSubscription`, `bulkSendUsesFewStatements`, `DispatchJobTest.aSendInsertsClaimedRowsWithOneStatement` |
| AC-OUT-2 Standard envelope and headers | `HookOutbound.envelope`, `HookDelivery.Attempt.request` | Apex: `OutboundTest.thePayloadIsTheStandardEnvelope`, `DispatchJobTest.a2xxDeliversWithSignedStandardHeaders`; Node: the published Standard Webhooks vector |
| AC-OUT-3 Same event Id: one row for each subscription | `Dedup_Key__c` | Apex: `OutboundTest.theSameEventIdTwiceMakesOneDelivery` (two subscriptions) |
| AC-OUT-4 `Delivered`, status, error, 2000-character response | `HookDelivery.apply`, `outcomeOf` | Apex: `DispatchJobTest.a2xxDeliversWithSignedStandardHeaders`, `a500RetriesWithBackoffAndKeepsTheResponse`, `DeliveryTest.prepareSendAndRecordADelivery` |
| AC-OUT-5 Claim with `FOR UPDATE`, token and lease | `HookQueueChannel.claim`, `HookDelivery.saveAll` | Apex: `DispatchJobTest.theClaimSkipsInactiveLiveAndNotDueRows`, `aRowWithAShortLeaseWaitsForTheNextClaim`, `DeliveryTest.recordSkipsARowThatWasRedeliveredAfterTheRead`, `SweepTest.theSweepClaimsAnExpiredLease` |
| AC-OUT-6 Backoff with jitter and cap; `Retry-After` on 429 and 503 | `HookDispatchJob.retryDelay`, `HookBackoff`, `HookRetryAfter` | Apex: `DispatchJobTest.a500RetriesWithBackoffAndKeepsTheResponse`, `retryAfterIsUsedFor429And503`, `retryAfterOn503IsUsedAndCapped`, `aTimeoutRetries`, `aShortRetryArmsADelayedClaim`, `SecretsTest.backoffDoublesAndStopsAtTheCap`, `DeliveryTest.retryAfterAcceptsSecondsAndHttpDates` |
| AC-OUT-7 Maximum attempts, then `Failed` | `Attempt.maxAttempts`, `HookConfig.maxAttempts` | Apex: `DispatchJobTest.theLastAttemptFails`, `theSubscriptionMaxAttemptsWins`, `SecretsTest.configHasDefaultsWithNoRecord` |
| AC-OUT-8 410 fails and disables | `apply` GONE | Apex: `DispatchJobTest.a410FailsAndDisablesTheSubscription` |
| AC-OUT-9 Disable after N failures, reset on 2xx, pause rows | `apply`, `claim` filter, PAUSED | Apex: `DispatchJobTest.failuresInARowDisable`, `aSuccessResetsTheFailureCount`, `DeliveryTest.anInactiveSubscriptionPausesTheRow`, `recordDoesNotEnableADisabledSubscription` |
| AC-OUT-10 Batch size and timeout, chain when more are due | `HookConfig.batchSize`, `timeoutMs`, `HookDispatchJob` | Apex: `DispatchJobTest.oneJobSendsAtMostTheBatchSizeAndChains`, `aClaimJobClaimsAndChains`, `SecretsTest.configCapsTheBatchAndTheTimeout`. No test reads the timeout on the request: `HttpRequest` has no getter |
| AC-OUT-11 Redeliver | `HookOutbound.redeliver` | Apex: `DispatchJobTest.redeliverResetsAndDispatches`, `RevenantChannelTest.redeliverStartsANewGeneration` |
| AC-OUT-12 Flow actions | `HookSendAction`, `HookReplayAction` | Apex: `ActionsTest.sendActionSendsEachRequest`, `sendActionRejectsBadJson`, `replayActionSplitsByRecordType` |
| AC-OUT-13 Large payload throws | `HookOutbound.Prepared` | Apex: `OutboundTest.aLargePayloadThrows` |
| AC-OUT-14 No secret fails clearly | `Attempt.send` | Apex: `DispatchJobTest.aMissingSecretFailsWithAClearError`, `DeliveryTest.anErrorThatIsNotACalloutErrorGivesAConfigOutcome` |

## Security

| AC | Implementation | Evidence |
|----|----------------|----------|
| AC-SEC-1 Constant-time compare | `HookSigner.equalsConstantTime` (XOR over all characters) | Apex: `SignerTest.constantTimeEqualsComparesTheWholeValue`; code review: each verifier compares with it. A test cannot prove timing |
| AC-SEC-2 Protected Custom Setting | `Hook_Secret__c` | Node: `metadata.test.mjs` |
| AC-SEC-3 Rotation with grace; revoke | `HookSecrets.rotate`, `put` | Apex: `SecretsTest.rotateKeepsThePreviousValueUntilTheGraceEnds`, `setSecretRevokesThePreviousValue`, `VerifiersTest.standardWebhooksAcceptsSvixHeadersAndAPreviousSecret`, `DispatchJobTest.aRotatedSecretSignsWithBoth` |
| AC-SEC-4 `https://` or `callout:` only | validation rule `Endpoint_Must_Be_Secure` | Apex: `OutboundTest.anHttpEndpointIsRejected`; Node: `metadata.test.mjs` |
| AC-SEC-5 No credential headers stored | `HookInbound.storedHeaders` | Apex: `InboundTest.aValidRequestStoresOneEventAndPublishes` (Authorization, Proxy-Authorization, Cookie), `theTokenHeaderIsNotStored` |
| AC-SEC-6 Guest permission set is minimal | `Hook_Guest` | Node: `metadata.test.mjs` |
| AC-SEC-7 Guest cannot use `NONE` | `HookInbound.handle` | Apex: `InboundTest.aGuestCannotUseAnEndpointWithNoCheck`, `a401GivesNoReason`, `aBadHandlerIsNotMadeBeforeVerification` |

## Sweep

| AC | Implementation | Evidence |
|----|----------------|----------|
| AC-SW-1 Claim due rows, publish due and stale inbound | `HookSweep.run`, `republishInbound` | Apex: `SweepTest.theSweepClaimsDueDeliveries`, `theSweepStartsNoJobWhenNothingIsDue`, `theSweepPublishesDueAndStaleInbound`, `aFailedPublishIsPublishedAgainWithNoAttempt`, `theSweepClaimsAnExpiredLease` |
| AC-SW-2 Four jobs, every 15 minutes | `HookSweep.schedule`, `unschedule` | Apex: `SweepTest.scheduleMakesFourJobsAndUnscheduleRemovesThem`, `theScheduleRunsAtMinutes0And15And30And45`, `theSchedulableRunsTheSweep` |
| AC-SW-3 Purge after retention | `HookSweep.purge` | Apex: `SweepTest.theSweepDeletesOldDoneRows`, `SecretsTest.configHasDefaultsWithNoRecord` (default 30) |

## Revenant adapter

| AC | Implementation | Evidence |
|----|----------------|----------|
| AC-RV-1 One workflow for each delivery, `startOrGet` | `HookRevenantChannel` | Apex: `RevenantChannelTest.dispatchStartsOneWorkflowForEachDelivery`, `redeliverStartsANewGeneration`, `theSweepDoesNotClaimRevenantRows` |
| AC-RV-2 CalloutStep outcomes | `HookRevenantDelivery.DeliverStep` | Apex: `RevenantDeliveryTest`, 14 tests, including `theWorkflowDeliversEndToEnd` (harness, 503 then 200) |
| AC-RV-3 Start or signal with the dedup key | `HookRevenantInboundHandler` | Apex: `RevenantInboundHandlerTest`, 8 tests |
| AC-RV-4 Core needs no Revenant | folder split | `npm run check:apex-compile:core`: 0 issues (CI step) |

## Quality

| AC | Evidence |
|----|----------|
| AC-Q-1 A test for each AC; 85% coverage | 145 Apex test methods. The tables above give a test for each AC. **Coverage is not measured**: the org workflow needs the secret |
| AC-Q-2 apex-ls 0 issues | CI job "Apex compile (apex-ls)" |
| AC-Q-3 Prettier and Code Analyzer | CI jobs "Apex format" and "Code Analyzer" |
| AC-Q-4 Global API equal to the manifest | `api.test.mjs` |
| AC-Q-5 Vectors checked twice | `vectors.test.mjs` (with the published Standard Webhooks and GitHub values); `SignerTest`, `VerifiersTest` |
| AC-Q-6 Docs in ASD-STE100 | README, CLAUDE.md, docs/api.md, 4 ADRs, design, this page. The docs review rewrote the worst sentences |

## Open gap

- **Org test run and coverage (AC-Q-1).** Add the secret `DEVHUB_SFDX_AUTH_URL` to `madmax983/hook`. The PR has the label `run-org-tests`, so the next push runs the tests and the 85% gate.
