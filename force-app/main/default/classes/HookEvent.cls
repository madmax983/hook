/**
 * @description One outbound event for Hook.send.
 */
global inherited sharing class HookEvent {
  /** @description The event type, for example order.paid. */
  global String eventType { get; private set; }
  /** @description The payload. Hook serializes it as JSON. */
  global Object payload { get; private set; }
  /** @description The event Id, or null to make one. */
  global String eventId { get; private set; }

  /**
   * @description Makes an event.
   * @param eventType The event type.
   * @param payload The payload.
   */
  global HookEvent(String eventType, Object payload) {
    this.eventType = eventType;
    this.payload = payload;
  }

  /**
   * @description Sets the event Id. The same Id twice makes one delivery for each subscription.
   * @param eventId The event Id.
   * @return This event.
   */
  global HookEvent withId(String eventId) {
    this.eventId = eventId;
    return this;
  }
}
