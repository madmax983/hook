/**
 * @description The Hook clock. Tests can fix the time.
 */
public inherited sharing class HookClock {
  /** @description When set, the clock gives this Unix time in seconds. */
  @TestVisible
  private static Long fixedSeconds;

  /**
   * @description Gives the Unix time in seconds.
   * @return The seconds since 1970-01-01T00:00:00Z.
   */
  public static Long nowSeconds() {
    return fixedSeconds != null
      ? fixedSeconds
      : Datetime.now().getTime() / 1000;
  }

  /**
   * @description Gives the current time.
   * @return The time.
   */
  public static Datetime now() {
    return fixedSeconds != null
      ? Datetime.newInstance(fixedSeconds * 1000)
      : Datetime.now();
  }
}
