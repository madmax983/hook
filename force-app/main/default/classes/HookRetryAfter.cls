/**
 * @description Reads a Retry-After header: seconds or an HTTP-date.
 */
public inherited sharing class HookRetryAfter {
  /** @description Largest Retry-After that Hook uses, in seconds. */
  public static final Integer MAX_SECONDS = 86400;
  private static final List<String> MONTHS = new List<String>{
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  };

  /**
   * @description Reads a Retry-After value.
   * @param raw The header value.
   * @return The seconds, at most MAX_SECONDS, or null for a missing, zero, past or bad value.
   */
  public static Integer seconds(String raw) {
    String value = raw == null ? '' : raw.trim();
    Long seconds;
    if (value.isNumeric()) {
      seconds = value.length() > 9 ? MAX_SECONDS : Long.valueOf(value);
    } else {
      Datetime at = parseHttpDate(value);
      seconds = at == null
        ? null
        : at.getTime() / 1000 - HookClock.nowSeconds();
    }
    if (seconds == null || seconds < 1) {
      return null;
    }
    return Math.min(seconds, (Long) MAX_SECONDS).intValue();
  }

  // Parses an IMF-fixdate, for example "Tue, 14 Nov 2023 22:14:20 GMT".
  private static Datetime parseHttpDate(String raw) {
    List<String> parts = raw.split(' ');
    if (parts.size() != 6 || parts[5] != 'GMT') {
      return null;
    }
    Integer month = MONTHS.indexOf(parts[2]) + 1;
    List<String> clock = parts[4].split(':');
    if (month == 0 || clock.size() != 3) {
      return null;
    }
    try {
      return Datetime.newInstanceGmt(
        Integer.valueOf(parts[3]),
        month,
        Integer.valueOf(parts[1]),
        Integer.valueOf(clock[0]),
        Integer.valueOf(clock[1]),
        Integer.valueOf(clock[2])
      );
    } catch (TypeException e) {
      return null;
    }
  }
}
