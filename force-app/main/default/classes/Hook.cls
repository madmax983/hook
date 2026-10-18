/**
 * @description The Hook facade. Send outbound webhooks, replay, manage
 * secrets and schedule the sweep.
 */
global without sharing class Hook {
  private Hook() {
    return;
  }

  /**
   * @description Sends an event to each active subscription whose filter matches.
   * It makes no callout in this transaction. It is safe in a trigger.
   * @param eventType The event type, for example order.paid.
   * @param payload The data. Hook serializes it as JSON.
   * @return The event Id.
   */
  global static String send(String eventType, Object payload) {
    return send(eventType, payload, null);
  }

  /**
   * @description Sends an event with a given Id. The same Id twice makes one
   * delivery for each subscription.
   * @param eventType The event type.
   * @param payload The data.
   * @param eventId The event Id, or null to make one.
   * @return The event Id.
   */
  global static String send(String eventType, Object payload, String eventId) {
    return send(
      new List<HookEvent>{ new HookEvent(eventType, payload).withId(eventId) }
    )[0];
  }

  /**
   * @description Sends events in bulk.
   * @param events The events.
   * @return The event Ids, in order.
   */
  global static List<String> send(List<HookEvent> events) {
    return HookOutbound.send(events);
  }

  /**
   * @description Sends deliveries again from attempt 1.
   * @param deliveryIds The Hook_Delivery__c Ids.
   */
  global static void redeliver(Set<Id> deliveryIds) {
    HookOutbound.redeliver(deliveryIds);
  }

  /**
   * @description Processes inbound events again from attempt 1.
   * @param inboundIds The Hook_Inbound_Event__c Ids.
   */
  global static void replayInbound(Set<Id> inboundIds) {
    List<Hook_Inbound_Event__c> rows = [
      SELECT Id
      FROM Hook_Inbound_Event__c
      WHERE Id IN :inboundIds
      WITH SYSTEM_MODE
    ];
    for (Hook_Inbound_Event__c rec : rows) {
      rec.Status__c = 'Pending';
      rec.Attempts__c = 0;
      rec.Next_Attempt_At__c = null;
      rec.Last_Error__c = null;
    }
    HookInboundDispatcher.publish(rows);
    update as system rows;
  }

  /**
   * @description Sets a secret, for example the signing secret that a provider gives.
   * @param name The secret name. 1 to 38 characters.
   * @param value The value.
   */
  global static void setSecret(String name, String value) {
    HookSecrets.put(name, value);
  }

  /**
   * @description Makes a new whsec_ secret. The old value stays valid for the grace time.
   * @param name The secret name.
   * @param graceHours Hours to keep the old value.
   * @return The new value. Give it to the subscriber.
   */
  global static String rotateSecret(String name, Integer graceHours) {
    return HookSecrets.rotate(name, graceHours);
  }

  /**
   * @description Schedules the sweep every 15 minutes.
   */
  global static void scheduleSweep() {
    HookSweep.schedule();
  }

  /**
   * @description Removes the scheduled sweep.
   */
  global static void unscheduleSweep() {
    HookSweep.unschedule();
  }
}
