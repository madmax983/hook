/**
 * @description Tests for the Flow actions and the Flow handler (AC-OUT-12,
 * AC-IN-13).
 */
@IsTest
private class HookActionsTest {
  @IsTest
  static void sendActionSendsEachRequest() {
    HookTestSupport.settings();
    HookTestSupport.subscription('s', '*');
    HookSendAction.Request a = new HookSendAction.Request();
    a.eventType = 'order.paid';
    a.payloadJson = '{"orderId":"o-1"}';
    a.eventId = 'evt_flow_1';
    HookSendAction.Request b = new HookSendAction.Request();
    b.eventType = 'order.shipped';

    List<HookSendAction.Result> results = HookSendAction.send(
      new List<HookSendAction.Request>{ a, b }
    );

    Assert.areEqual(2, results.size());
    Assert.areEqual('evt_flow_1', results[0].eventId);
    Assert.isTrue(results[1].eventId.startsWith('msg_'));
    Hook_Delivery__c d = [
      SELECT Payload__c
      FROM Hook_Delivery__c
      WHERE Event_Id__c = 'evt_flow_1'
    ];
    Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
      d.Payload__c
    );
    Assert.areEqual(
      'o-1',
      ((Map<String, Object>) body.get('data')).get('orderId')
    );
  }

  @IsTest
  static void sendActionRejectsBadJson() {
    HookSendAction.Request a = new HookSendAction.Request();
    a.eventType = 'order.paid';
    a.payloadJson = '{not json';
    try {
      HookSendAction.send(new List<HookSendAction.Request>{ a });
      Assert.fail('Expected a HookException');
    } catch (HookException e) {
      Assert.isTrue(e.getMessage().contains('payloadJson'), e.getMessage());
    }
  }

  @IsTest
  static void replayActionSplitsByRecordType() {
    HookTestSupport.settings();
    HookTestSupport.endpoint('e', 'NONE');
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'Failed');
    Hook_Inbound_Event__c rec = new Hook_Inbound_Event__c(
      Endpoint__c = 'e',
      Event_Id__c = 'x',
      Dedup_Key__c = 'e:x',
      Body__c = '{}',
      Status__c = 'Failed',
      Attempts__c = 4,
      Received_At__c = Datetime.now()
    );
    insert rec;
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(200, '', null)
    );

    Test.startTest();
    HookReplayAction.replay(new List<Id>{ d.Id, rec.Id, null });
    Test.stopTest();

    Assert.areEqual('Delivered', HookTestSupport.reload(d.Id).Status__c);
    Assert.areEqual(
      'Processed',
      [SELECT Status__c FROM Hook_Inbound_Event__c].Status__c
    );
  }

  @IsTest
  static void flowHandlerStartsTheConfiguredFlow() {
    RecordingLauncher launcher = new RecordingLauncher();
    HookFlowHandler.launcher = launcher;
    HookTestSupport.settings();
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('e', 'NONE');
    ep.Handler_Class__c = 'HookFlowHandler';
    ep.Handler_Config__c = '{"flow":"Process_Webhook"}';
    Hook_Inbound_Event__c rec = new Hook_Inbound_Event__c(
      Endpoint__c = 'e',
      Event_Id__c = 'f-1',
      Event_Type__c = 'thing.made',
      Dedup_Key__c = 'e:f-1',
      Body__c = '{"a":1}',
      Status__c = 'Pending',
      Attempts__c = 0,
      Received_At__c = Datetime.now()
    );
    insert rec;

    HookInboundDispatcher.dispatch(new Set<Id>{ rec.Id });

    Assert.areEqual('Process_Webhook', launcher.flowName);
    Assert.areEqual('thing.made', launcher.inputs.get('eventType'));
    Assert.areEqual('f-1', launcher.inputs.get('eventId'));
    Assert.areEqual('{"a":1}', launcher.inputs.get('body'));
    Assert.areEqual('e', launcher.inputs.get('endpoint'));
    Assert.areEqual(rec.Id, launcher.inputs.get('recordId'));
    Assert.areEqual(
      'Processed',
      [SELECT Status__c FROM Hook_Inbound_Event__c].Status__c
    );
  }

  @IsTest
  static void flowHandlerNeedsAFlowName() {
    HookTestSupport.settings();
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('e', 'NONE');
    ep.Handler_Class__c = 'HookFlowHandler';
    ep.Handler_Config__c = '{}';
    Hook_Inbound_Event__c rec = new Hook_Inbound_Event__c(
      Endpoint__c = 'e',
      Event_Id__c = 'f-2',
      Dedup_Key__c = 'e:f-2',
      Body__c = '{}',
      Status__c = 'Pending',
      Attempts__c = 0,
      Received_At__c = Datetime.now()
    );
    insert rec;
    HookInboundDispatcher.dispatch(new Set<Id>{ rec.Id });
    Hook_Inbound_Event__c after = [
      SELECT Status__c, Last_Error__c
      FROM Hook_Inbound_Event__c
    ];
    Assert.areEqual('Retrying', after.Status__c);
    Assert.isTrue(after.Last_Error__c.contains('flow'), after.Last_Error__c);
  }

  @IsTest
  static void theDefaultLauncherStartsARealFlow() {
    try {
      new HookFlowHandler.FlowLauncher()
        .start('Hook_No_Such_Flow', new Map<String, Object>());
      Assert.fail('Expected an exception');
    } catch (Exception e) {
      Assert.isNotNull(e.getMessage());
    }
  }

  /**
   * @description Keeps the Flow name and inputs.
   */
  private class RecordingLauncher implements HookFlowHandler.Launcher {
    public String flowName;
    public Map<String, Object> inputs;

    /**
     * @description Keeps the values.
     * @param flowName The Flow name.
     * @param inputs The inputs.
     */
    public void start(String flowName, Map<String, Object> inputs) {
      this.flowName = flowName;
      this.inputs = inputs;
    }
  }
}
