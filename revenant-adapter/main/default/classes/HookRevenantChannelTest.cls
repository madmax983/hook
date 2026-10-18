/**
 * @description Tests for the Revenant delivery channel (AC-RV-1).
 */
@IsTest
private class HookRevenantChannelTest {
  @IsTest
  static void dispatchStartsOneWorkflowForEachDelivery() {
    HookTestSupport.settings();
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    sub.Channel__c = 'HookRevenantChannel';
    update sub;
    HookDelivery.transport = new HookTestSupport.FakeTransport(
      new List<Integer>{ 200 }
    );

    Test.startTest();
    Hook.send('order.paid', null, 'evt_a');
    Hook.send('order.paid', null, 'evt_b');
    List<Hook_Delivery__c> rows = [SELECT Id, Channel__c FROM Hook_Delivery__c];
    new HookRevenantChannel().dispatch(new List<Id>{ rows[0].Id });
    Test.stopTest();

    Assert.areEqual(2, rows.size());
    for (Hook_Delivery__c d : rows) {
      Assert.areEqual('HookRevenantChannel', d.Channel__c);
      WorkflowEngine.WorkflowStatus status = WorkflowStatusRead.getStatus(
        HookRevenantChannel.correlationKey(d.Id, 0)
      );
      Assert.isNotNull(status, 'one workflow for each delivery');
      Assert.areEqual(HookRevenantDelivery.WORKFLOW, status.definitionName);
    }
    Assert.areEqual(
      2,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Workflow_Name__c = :HookRevenantDelivery.WORKFLOW
      ],
      'a second dispatch starts nothing new'
    );
  }

  @IsTest
  static void redeliverStartsANewGeneration() {
    HookTestSupport.settings();
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    sub.Channel__c = 'HookRevenantChannel';
    update sub;
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'Failed');
    d.Channel__c = 'HookRevenantChannel';
    update d;
    HookDelivery.transport = new HookTestSupport.FakeTransport(
      new List<Integer>{ 200 }
    );

    Test.startTest();
    Hook.redeliver(new Set<Id>{ d.Id });
    Test.stopTest();

    Assert.isNotNull(
      WorkflowStatusRead.getStatus(HookRevenantChannel.correlationKey(d.Id, 1))
    );
  }

  @IsTest
  static void theSweepDoesNotClaimRevenantRows() {
    HookTestSupport.settings();
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'Pending');
    d.Channel__c = 'HookRevenantChannel';
    update d;
    Assert.isNull(HookQueueChannel.claim(null, 10));
  }
}
