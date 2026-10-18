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
  /** @description Attempts for a thrown error, for example a DML error in record(). */
  public static final Integer THROWN_ERROR_ATTEMPTS = 3;

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
   * Revenant final attempt both end the retries.
   */
  public class DeliverStep implements WorkflowStep, CalloutStep, AutoRetryConfigurable {
    /**
     * @description Sends one attempt and maps the outcome to a step result.
     * @param ctx The step context. The workflow input holds deliveryId.
     * @return COMPLETE for 2xx, SLEEP for Retry-After, RETRY, or FAIL.
     */
    public StepResult execute(StepContext ctx) {
      Object raw = HookJson.valueAt(
        HookJson.parse(ctx.workflowInputJson),
        'deliveryId'
      );
      HookDelivery.Attempt attempt = raw == null
        ? null
        : HookDelivery.prepare(Id.valueOf(String.valueOf(raw)));
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
        attempt.record(Datetime.now().addSeconds(outcome.retryAfterSeconds));
        return StepResult.sleep(outcome.retryAfterSeconds);
      }
      attempt.record(
        Datetime.now()
          .addSeconds(
            BASE_DELAY_SECONDS *
            (Integer) Math.pow(2, Math.min(attempt.attempts, 20))
          )
      );
      return StepResult.retry(
        new RetryPolicy(BASE_DELAY_SECONDS, (Double) 2.0, attempt.maxAttempts)
      );
    }

    /**
     * @description Retry policy for a thrown error.
     * @return Three attempts: 60 s, then 120 s.
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
