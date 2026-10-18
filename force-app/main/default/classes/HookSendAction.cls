/**
 * @description Flow action "Send Webhook".
 */
global with sharing class HookSendAction {
  /**
   * @description Sends each request with Hook.send.
   * @param requests The requests.
   * @return The event Ids, in order.
   */
  @InvocableMethod(
    label='Send Webhook'
    description='Sends a signed webhook to each matching subscription.'
    category='Hook'
  )
  global static List<Result> send(List<Request> requests) {
    List<HookEvent> events = new List<HookEvent>();
    for (Request r : requests) {
      Object payload = null;
      if (String.isNotBlank(r.payloadJson)) {
        try {
          payload = JSON.deserializeUntyped(r.payloadJson);
        } catch (JSONException e) {
          throw new HookException(
            'payloadJson is not valid JSON: ' + e.getMessage()
          );
        }
      }
      events.add(new HookEvent(r.eventType, payload).withId(r.eventId));
    }
    List<Result> results = new List<Result>();
    for (String id : Hook.send(events)) {
      Result res = new Result();
      res.eventId = id;
      results.add(res);
    }
    return results;
  }

  /** @description The input of one send. */
  global class Request {
    /** @description The event type, for example order.paid. */
    @InvocableVariable(label='Event Type' required=true)
    global String eventType;
    /** @description The data as JSON. */
    @InvocableVariable(label='Payload JSON')
    global String payloadJson;
    /** @description The event Id. Blank makes one. */
    @InvocableVariable(label='Event Id')
    global String eventId;
  }

  /** @description The output of one send. */
  global class Result {
    /** @description The event Id. */
    @InvocableVariable(label='Event Id')
    global String eventId;
  }
}
