/**
 * @description Flow action "Replay Webhook". A delivery Id redelivers. An
 * inbound event Id replays.
 */
global with sharing class HookReplayAction {
  /**
   * @description Replays each record by its type. Other Ids are skipped.
   * @param recordIds Hook_Delivery__c or Hook_Inbound_Event__c Ids.
   */
  @InvocableMethod(
    label='Replay Webhook'
    description='Sends a delivery again, or processes an inbound event again.'
    category='Hook'
  )
  global static void replay(List<Id> recordIds) {
    Set<Id> deliveries = new Set<Id>();
    Set<Id> inbound = new Set<Id>();
    for (Id id : recordIds) {
      if (id == null) {
        continue;
      }
      if (id.getSObjectType() == Hook_Delivery__c.SObjectType) {
        deliveries.add(id);
      } else if (id.getSObjectType() == Hook_Inbound_Event__c.SObjectType) {
        inbound.add(id);
      }
    }
    if (!deliveries.isEmpty()) {
      Hook.redeliver(deliveries);
    }
    if (!inbound.isEmpty()) {
      Hook.replayInbound(inbound);
    }
  }
}
