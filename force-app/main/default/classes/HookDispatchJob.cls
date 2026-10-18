/**
 * @description Sends claimed deliveries (ADR 0002). With a token it sends the
 * rows of the token, writes the results, claims the next due rows and chains.
 * With no token it only claims and chains. It must see every row, so it runs
 * without sharing.
 */
public without sharing class HookDispatchJob implements Queueable, Database.AllowsCallouts {
  /** @description Longest retry delay that a delayed job covers. The sweep covers longer ones. */
  private static final Integer DELAYED_JOB_MAX_SECONDS = 600;

  /** @description The claim token, or null for a claim-only job. */
  public final String token;

  /**
   * @description Makes a job.
   * @param token The claim token, or null for a claim-only job.
   */
  public HookDispatchJob(String token) {
    this.token = token;
  }

  /**
   * @description Runs the job.
   * @param ctx The context.
   */
  public void execute(QueueableContext ctx) {
    Boolean wasInJob = HookAsync.inJob;
    HookAsync.inJob = true;
    try {
      if (token == null) {
        claimAndChain(null);
        return;
      }
      Integer shortest = sendClaimed();
      if (
        !claimAndChain(token) &&
        shortest != null &&
        shortest <= DELAYED_JOB_MAX_SECONDS
      ) {
        HookAsync.enqueue(
          new HookDispatchJob(null),
          Math.max(1, Math.ceil(shortest / 60.0).intValue())
        );
      }
    } finally {
      HookAsync.inJob = wasInJob;
    }
  }

  // Sends the rows of the token. Gives the shortest retry delay, or null.
  private Integer sendClaimed() {
    List<HookDelivery.Attempt> sent = new List<HookDelivery.Attempt>();
    Integer shortest;
    for (
      HookDelivery.Attempt a : HookDelivery.claimed(
        token,
        HookConfig.batchSize()
      )
    ) {
      if (Limits.getCallouts() >= Limits.getLimitCallouts()) {
        break;
      }
      HookDelivery.Outcome outcome = a.send();
      Integer delay = retryDelay(a, outcome);
      if (delay != null) {
        a.nextAttemptAt = HookClock.now().addSeconds(delay);
        shortest = shortest == null ? delay : Math.min(shortest, delay);
      }
      sent.add(a);
    }
    HookDelivery.saveAll(sent);
    return shortest;
  }

  /**
   * @description Gives the delay before the next attempt.
   * @param a The attempt.
   * @param outcome Its outcome.
   * @return The seconds, or null when no attempt is left or a retry cannot help.
   */
  public static Integer retryDelay(
    HookDelivery.Attempt a,
    HookDelivery.Outcome outcome
  ) {
    Integer made = a.attempts + 1;
    if (!outcome.isRetryable() || made >= a.maxAttempts) {
      return null;
    }
    if (outcome.retryAfterSeconds != null) {
      return Math.min(outcome.retryAfterSeconds, HookConfig.maxDelaySeconds());
    }
    return HookBackoff.delaySeconds(
      made,
      HookConfig.baseDelaySeconds(),
      HookConfig.maxDelaySeconds()
    );
  }

  private static Boolean claimAndChain(String current) {
    if (!HookAsync.canEnqueue()) {
      return false;
    }
    String next = HookQueueChannel.claim(current, HookConfig.batchSize());
    return next != null && HookAsync.enqueue(new HookDispatchJob(next), 0);
  }
}
