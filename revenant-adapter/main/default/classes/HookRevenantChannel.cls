/**
 * @description A channel that sends each delivery as a durable Revenant
 * workflow (ADR 0004). Set Hook_Subscription__c.Channel__c to HookRevenantChannel.
 */
public without sharing class HookRevenantChannel implements HookChannel {
  /**
   * @description Gives the correlation key of a delivery workflow. A
   * redelivery adds 1 to the generation, so it starts a new workflow.
   * @param deliveryId The Hook_Delivery__c Id.
   * @param generation The Generation__c value.
   * @return The key.
   */
  public static String correlationKey(Id deliveryId, Integer generation) {
    return 'hook-delivery:' + deliveryId + ':' + generation;
  }

  /**
   * @description Starts or gets one workflow for each delivery. For a
   * redelivery, it cancels the workflow of the last generation when that
   * workflow still runs, so two workflows never send the same row.
   * @param deliveryIds The Hook_Delivery__c Ids.
   */
  public void dispatch(List<Id> deliveryIds) {
    List<WorkflowEngine.StartRequest> requests = new List<WorkflowEngine.StartRequest>();
    List<String> previous = new List<String>();
    for (Hook_Delivery__c d : [
      SELECT Id, Generation__c
      FROM Hook_Delivery__c
      WHERE Id IN :deliveryIds
      WITH SYSTEM_MODE
    ]) {
      Integer generation = d.Generation__c == null
        ? 0
        : d.Generation__c.intValue();
      if (generation > 0) {
        previous.add(correlationKey(d.Id, generation - 1));
      }
      requests.add(
        new WorkflowEngine.StartRequest(
          HookRevenantDelivery.WORKFLOW,
          correlationKey(d.Id, generation),
          new Map<String, Object>{ 'deliveryId' => d.Id }
        )
      );
    }
    cancelRunning(previous);
    if (!requests.isEmpty()) {
      WorkflowEngine.startOrGet(requests);
    }
  }

  @SuppressWarnings('PMD.OperationWithLimitsInLoop')
  private static void cancelRunning(List<String> keys) {
    if (keys.isEmpty()) {
      return;
    }
    for (
      WorkflowEngine.WorkflowStatus status : WorkflowStatusRead.getStatus(keys)
    ) {
      if (status != null && !status.isTerminal) {
        WorkflowEngine.cancel(status.instanceId);
      }
    }
  }
}
