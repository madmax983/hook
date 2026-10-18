/**
 * @description Exponential backoff with jitter: base * 2^(attempt - 1),
 * capped, then +/- 20%.
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
    Decimal raw = Math.min(
      Decimal.valueOf(baseSeconds) * factor,
      Decimal.valueOf(maxSeconds)
    );
    if (jitterEnabled) {
      raw = raw * (0.8 + 0.4 * Decimal.valueOf(Math.random()));
    }
    return Math.max(1, raw.round(System.RoundingMode.HALF_UP).intValue());
  }
}
