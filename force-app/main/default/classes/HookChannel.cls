/**
 * @description Sends outbound deliveries. Set Hook_Subscription__c.Channel__c,
 * or Hook_Setting__mdt.Default_Channel__c, to the class name.
 */
global interface HookChannel {
  /**
   * @description Starts the delivery of the rows. Hook calls it in the
   * transaction that made the rows. Do not call out here.
   * @param deliveryIds The Hook_Delivery__c Ids.
   */
  void dispatch(List<Id> deliveryIds);
}
