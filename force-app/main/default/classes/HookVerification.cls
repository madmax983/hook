/**
 * @description The result of a verifier.
 */
global inherited sharing class HookVerification {
  /** @description True when the request is authentic. */
  global Boolean isValid { get; private set; }
  /** @description Why the request is not valid. */
  global String reason { get; private set; }
  /** @description The provider event Id, or null. */
  global String eventId { get; private set; }
  /** @description The provider event type, or null. */
  global String eventType { get; private set; }

  private HookVerification() {
    this.isValid = false;
  }

  /**
   * @description Makes a valid result.
   * @param eventId The provider event Id, or null.
   * @param eventType The provider event type, or null.
   * @return The result.
   */
  global static HookVerification valid(String eventId, String eventType) {
    HookVerification v = new HookVerification();
    v.isValid = true;
    v.eventId = String.isBlank(eventId) ? null : eventId;
    v.eventType = String.isBlank(eventType) ? null : eventType;
    return v;
  }

  /**
   * @description Makes a result that is not valid.
   * @param reason Why. Hook stores no request and returns 401.
   * @return The result.
   */
  global static HookVerification invalid(String reason) {
    HookVerification v = new HookVerification();
    v.reason = reason;
    return v;
  }
}
