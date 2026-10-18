/**
 * @description Exponential backoff with jitter: base * 2^(attempt - 1),
 * +/- 20%, then capped.
 */
public inherited sharing class HookBackoff {
  /** @description Tests set false to get exact delays. */
  @TestVisible
  private static Boolean jitterEnabled = true;

  /**
   * @description Gives the delay after a failed attempt.
   * @param attempt The failed attempt number, from 1.
   * @param baseSeconds The first delay.
   * @param maxSeconds The cap.
   * @return The delay in seconds. At least 1.
   */
  public static Integer delaySeconds(
    Integer attempt,
    Integer baseSeconds,
    Integer maxSeconds
  ) {
    Integer exponent = Math.min(Math.max(attempt, 1) - 1, 30);
    Decimal factor = Decimal.valueOf(Math.pow(2, exponent));
    Decimal raw = Decimal.valueOf(baseSeconds) * factor;
    if (jitterEnabled) {
      raw = raw * (0.8 + 0.4 * Decimal.valueOf(Math.random()));
    }
    // The cap comes after the jitter, so no delay is longer than the cap.
    raw = Math.min(raw, Decimal.valueOf(maxSeconds));
    return Math.max(1, raw.round(System.RoundingMode.HALF_UP).intValue());
  }
}
