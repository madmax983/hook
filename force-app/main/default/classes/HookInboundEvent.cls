/**
 * @description One stored inbound event, as a handler gets it.
 */
global inherited sharing class HookInboundEvent {
  /** @description The Hook_Inbound_Event__c Id. */
  global Id recordId { get; private set; }
  /** @description The endpoint name. */
  global String endpoint { get; private set; }
  /** @description The provider event Id. */
  global String eventId { get; private set; }
  /** @description The provider event type, or null. */
  global String eventType { get; private set; }
  /** @description The unique key of the event. Use it as an idempotency key. */
  global String dedupKey { get; private set; }
  /** @description The raw body. */
  global String body { get; private set; }
  /** @description This attempt, from 1. */
  global Integer attempt { get; private set; }
  /** @description Hook_Endpoint__mdt.Handler_Config__c. */
  global String config { get; private set; }

  private final Map<String, String> headers;
  private Object parsed;
  private Boolean isParsed = false;

  /**
   * @description Makes the event from its row.
   * @param rec The row.
   * @param ep The endpoint, or null.
   * @param attempt This attempt.
   */
  public HookInboundEvent(
    Hook_Inbound_Event__c rec,
    Hook_Endpoint__mdt ep,
    Integer attempt
  ) {
    this.recordId = rec.Id;
    this.endpoint = rec.Endpoint__c;
    this.eventId = rec.Event_Id__c;
    this.eventType = rec.Event_Type__c;
    this.dedupKey = rec.Dedup_Key__c;
    this.body = rec.Body__c;
    this.attempt = attempt;
    this.config = ep == null ? null : ep.Handler_Config__c;
    this.headers = new Map<String, String>();
    Object raw = HookJson.parse(rec.Headers__c);
    if (raw instanceof Map<String, Object>) {
      Map<String, Object> values = (Map<String, Object>) raw;
      for (String key : values.keySet()) {
        headers.put(
          key.toLowerCase(),
          values.get(key) == null ? null : String.valueOf(values.get(key))
        );
      }
    }
  }

  /**
   * @description Reads a stored header. The name ignores case.
   * @param name The header name.
   * @return The value, or null.
   */
  global String header(String name) {
    return name == null ? null : headers.get(name.toLowerCase());
  }

  /**
   * @description Gives the parsed body.
   * @return The body as untyped JSON, or null when it is not JSON.
   */
  global Object json() {
    if (!isParsed) {
      parsed = HookJson.parse(body);
      isParsed = true;
    }
    return parsed;
  }

  /**
   * @description Reads a value from the body at a dot path.
   * @param path The path, for example data.object.id. A number is a list index.
   * @return The value, or null.
   */
  global Object valueAt(String path) {
    return HookJson.valueAt(json(), path);
  }
}
