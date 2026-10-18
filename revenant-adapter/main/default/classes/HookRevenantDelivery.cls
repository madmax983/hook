/**
 * @description A one-step Revenant workflow that sends one Hook delivery.
 * Revenant gives the durable retry, sleep, watchdog and audit history.
 */
public inherited sharing class HookRevenantDelivery {
  /** @description The workflow name. */
  public static final String WORKFLOW = 'HookRevenantDelivery.DeliveryWorkflow';
  /** @description The step name. */
  public static final String STEP = 'HookRevenantDelivery.DeliverStep';
  /** @description First retry delay, in seconds. It doubles each attempt. */
  public static final Integer BASE_DELAY_SECONDS = 60;
  /**
   * @description Attempts for a thrown error. Revenant counts them with the
   * HTTP retries, so it is equal to the Hook default.
   */
  public static final Integer THROWN_ERROR_ATTEMPTS = 10;

  /**
   * @description The workflow: DeliverStep only.
   */
  public class DeliveryWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ STEP };
    }

    /**
     * @description Names the first step.
     * @return The deliver step.
     */
    public String getInitialStep() {
      return STEP;
    }

    /**
     * @description Ends after the deliver step.
     * @param currentStepName The step that completed.
     * @param result The result.
     * @return Null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description Sends the delivery. CalloutStep: Revenant does no DML before
   * execute(), so the callout is legal. The Hook attempt count and the
   * Revenant final attempt both end the retries. When the subscription is not
   * active, the row goes back to Pending and the workflow fails. Redeliver
   * the row after you make the subscription active again.
   */
  public class DeliverStep implements WorkflowStep, CalloutStep, AutoRetryConfigurable {
    /**
     * @description Sends one attempt and maps the outcome to a step result.
     * @param ctx The step context. The workflow input holds deliveryId.
     * @return COMPLETE for 2xx, SLEEP for Retry-After, RETRY, or FAIL.
     */
    public StepResult execute(StepContext ctx) {
      Id deliveryId = deliveryIdFrom(ctx.workflowInputJson);
      HookDelivery.Attempt attempt = deliveryId == null
        ? null
        : HookDelivery.prepare(deliveryId);
      if (attempt == null) {
        return StepResult.fail('The Hook delivery is not found.');
      }
      if (attempt.isDelivered()) {
        return StepResult.complete(
          null,
          new Map<String, Object>{ 'status' => 'Delivered' }
        );
      }
      HookDelivery.Outcome outcome = attempt.send();
      try {
        return decide(ctx, attempt, outcome);
      } catch (Exception e) {
        // The callout is done, but record() failed, for example on a lock.
        // A retry sends again with the same webhook-id. The receiver deduplicates.
        return StepResult.retry(policy(attempt));
      }
    }

    private StepResult decide(
      StepContext ctx,
      HookDelivery.Attempt attempt,
      HookDelivery.Outcome outcome
    ) {
      if (outcome.isDelivered()) {
        attempt.record(null);
        return StepResult.complete(
          null,
          new Map<String, Object>{ 'statusCode' => outcome.statusCode }
        );
      }
      Boolean last =
        !outcome.isRetryable() ||
        attempt.attempts + 1 >= attempt.maxAttempts ||
        ctx.isFinalAttempt();
      if (last) {
        attempt.record(null);
        return StepResult.fail('Hook delivery failed: ' + outcome.error);
      }
      if (outcome.retryAfterSeconds != null) {
        attempt.record(displayTime(outcome.retryAfterSeconds));
        return StepResult.sleep(outcome.retryAfterSeconds);
      }
      Integer exponent = Math.min(Math.max(ctx.attempt, 1) - 1, 20);
      attempt.record(
        displayTime(BASE_DELAY_SECONDS * (Integer) Math.pow(2, exponent))
      );
      return StepResult.retry(policy(attempt));
    }

    private RetryPolicy policy(HookDelivery.Attempt attempt) {
      return new RetryPolicy(
        BASE_DELAY_SECONDS,
        (Double) 2.0,
        attempt.maxAttempts
      );
    }

    // The time for Next_Attempt_At__c. Revenant owns the real wait; the row
    // shows it. A replay does not read the value back.
    private Datetime displayTime(Integer seconds) {
      // revenant-lint-disable-next-line: display-only time, not read on replay
      return Datetime.now().addSeconds(seconds);
    }

    private Id deliveryIdFrom(String inputJson) {
      try {
        Object parsed = JSON.deserializeUntyped(inputJson);
        Object raw = parsed instanceof Map<String, Object>
          ? ((Map<String, Object>) parsed).get('deliveryId')
          : null;
        return raw == null ? null : Id.valueOf(String.valueOf(raw));
      } catch (Exception e) {
        return null;
      }
    }

    /**
     * @description Retry policy for a thrown error.
     * @return Ten attempts: 60 s, then doubled each time.
     */
    public RetryPolicy getAutoRetryPolicy() {
      return new RetryPolicy(
        BASE_DELAY_SECONDS,
        (Double) 2.0,
        THROWN_ERROR_ATTEMPTS
      );
    }
  }
}
