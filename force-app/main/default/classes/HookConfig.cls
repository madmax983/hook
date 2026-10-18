/**
 * @description Reads the org settings (Hook_Setting__mdt record Default).
 * A missing record or field gives the default value.
 */
public inherited sharing class HookConfig {
  /** @description Largest total callout time for one transaction, in ms. */
  private static final Integer CALLOUT_BUDGET_MS = 120000;

  /** @description The settings record. Tests set it. */
  @TestVisible
  private static Hook_Setting__mdt current {
    get {
      if (current == null) {
        current = Hook_Setting__mdt.getInstance('Default');
        if (current == null) {
          current = new Hook_Setting__mdt();
        }
      }
      return current;
    }
    set;
  }

  private static Integer read(Decimal value, Integer fallback) {
    return value == null ? fallback : value.intValue();
  }

  /**
   * @description Gives the callout timeout. Range 1 to 120000 ms.
   * @return The timeout in ms.
   */
  public static Integer timeoutMs() {
    return Math.max(
      1,
      Math.min(CALLOUT_BUDGET_MS, read(current.Timeout_Ms__c, 10000))
    );
  }

  /**
   * @description Gives the deliveries for one job. The total timeout stays at
   * or below 120 s, and the count stays at or below 100.
   * @return The batch size.
   */
  public static Integer batchSize() {
    Integer bySetting = Math.max(
      1,
      Math.min(100, read(current.Batch_Size__c, 10))
    );
    return Math.max(1, Math.min(bySetting, CALLOUT_BUDGET_MS / timeoutMs()));
  }

  /**
   * @description Gives the default maximum attempts.
   * @return The attempts. At least 1.
   */
  public static Integer maxAttempts() {
    return Math.max(1, read(current.Max_Attempts__c, 10));
  }

  /**
   * @description Gives the first retry delay.
   * @return The seconds.
   */
  public static Integer baseDelaySeconds() {
    return Math.max(1, read(current.Base_Delay_Seconds__c, 60));
  }

  /**
   * @description Gives the largest retry delay.
   * @return The seconds.
   */
  public static Integer maxDelaySeconds() {
    return Math.max(1, read(current.Max_Delay_Seconds__c, 21600));
  }

  /**
   * @description Gives the failed attempts in a row that disable a subscription.
   * @return The count. 0 is never.
   */
  public static Integer disableAfterFailures() {
    return Math.max(0, read(current.Disable_After_Failures__c, 50));
  }

  /**
   * @description Gives the lease of a claimed row. At least 3 minutes, so a
   * job with 120 s of callouts ends in its lease.
   * @return The minutes.
   */
  public static Integer leaseMinutes() {
    return Math.max(3, read(current.Lease_Minutes__c, 10));
  }

  /**
   * @description Gives the days to keep done rows.
   * @return The days.
   */
  public static Integer retentionDays() {
    return Math.max(1, read(current.Retention_Days__c, 30));
  }

  /**
   * @description Gives the channel for a subscription with no channel.
   * @return The class name.
   */
  public static String defaultChannel() {
    return String.isBlank(current.Default_Channel__c)
      ? HookQueueChannel.NAME
      : current.Default_Channel__c.trim();
  }
}
