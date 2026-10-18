/**
 * @description Tests for the Revenant inbound handler (AC-RV-3).
 */
@IsTest
private class HookRevenantInboundHandlerTest {
  private static Hook_Inbound_Event__c store(String config, String body) {
    HookTestSupport.settings();
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('rv', 'NONE');
    ep.Handler_Class__c = 'HookRevenantInboundHandler';
    ep.Handler_Config__c = config;
    Hook_Inbound_Event__c rec = new Hook_Inbound_Event__c(
      Endpoint__c = 'rv',
      Event_Id__c = 'evt_9',
      Event_Type__c = 'payment.succeeded',
      Dedup_Key__c = 'rv:evt_9',
      Body__c = body,
      Status__c = 'Pending',
      Attempts__c = 0,
      Received_At__c = Datetime.now()
    );
    insert rec;
    return rec;
  }

  private static String status(Id id) {
    return [
      SELECT Status__c, Last_Error__c
      FROM Hook_Inbound_Event__c
      WHERE Id = :id
    ]
    .Status__c;
  }

  @IsTest
  static void startModeStartsTheWorkflowWithTheEvent() {
    Hook_Inbound_Event__c rec = store(
      '{"mode":"start","workflow":"HookRevenantInboundHandlerTest.EchoWorkflow"}',
      '{"amount":5}'
    );
    Test.startTest();
    HookInboundDispatcher.dispatch(new Set<Id>{ rec.Id });
    HookInboundDispatcher.dispatch(new Set<Id>{ rec.Id });
    Test.stopTest();

    Assert.areEqual('Processed', status(rec.Id));
    List<Workflow_Instance__c> rows = [
      SELECT Correlation_Key__c, Input__c
      FROM Workflow_Instance__c
      WHERE Workflow_Name__c = 'HookRevenantInboundHandlerTest.EchoWorkflow'
    ];
    Assert.areEqual(1, rows.size());
    Assert.areEqual('rv:evt_9', rows[0].Correlation_Key__c);
  }

  @IsTest
  static void startModeCanReadTheKeyFromTheBody() {
    Hook_Inbound_Event__c rec = store(
      '{"mode":"start","workflow":"HookRevenantInboundHandlerTest.EchoWorkflow","keyPath":"order.id"}',
      '{"order":{"id":"o-77"}}'
    );
    HookInboundDispatcher.dispatch(new Set<Id>{ rec.Id });
    Assert.areEqual('Processed', status(rec.Id));
    Assert.isNotNull(WorkflowStatusRead.getStatus('o-77'));
  }

  @IsTest
  static void signalModeSignalsTheTargetWithTheDedupKey() {
    Id instanceId = WorkflowEngine.start(
      'HookRevenantInboundHandlerTest.EchoWorkflow',
      'order-1',
      null
    );
    Hook_Inbound_Event__c rec = store(
      '{"mode":"signal","signal":"Paid","keyPath":"data.orderKey"}',
      '{"data":{"orderKey":"order-1"}}'
    );
    HookInboundDispatcher.dispatch(new Set<Id>{ rec.Id });

    Assert.areEqual('Processed', status(rec.Id));
    Workflow_Signal__c sig = [
      SELECT Signal_Name__c, Idempotency_Key__c, Payload__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :instanceId
    ];
    Assert.areEqual('Paid', sig.Signal_Name__c);
    Assert.areEqual('rv:evt_9', sig.Idempotency_Key__c);
  }

  @IsTest
  static void aBadConfigFailsTheEvent() {
    Hook_Inbound_Event__c rec = store('{"mode":"dance"}', '{}');
    HookInboundDispatcher.dispatch(new Set<Id>{ rec.Id });
    Assert.areNotEqual('Processed', status(rec.Id));
    Assert.isTrue(
      [SELECT Last_Error__c FROM Hook_Inbound_Event__c]
        .Last_Error__c.contains('mode'),
      'the error names the field'
    );
  }

  @IsTest
  static void signalModeNeedsAKey() {
    Hook_Inbound_Event__c rec = store(
      '{"mode":"signal","signal":"Paid","keyPath":"missing"}',
      '{}'
    );
    HookInboundDispatcher.dispatch(new Set<Id>{ rec.Id });
    Assert.isTrue(
      [SELECT Last_Error__c FROM Hook_Inbound_Event__c]
        .Last_Error__c.contains('missing')
    );
  }

  /**
   * @description A one-step workflow that waits for the signal Paid.
   */
  public class EchoWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'HookRevenantInboundHandlerTest.WaitStep' };
    }

    /**
     * @description Names the first step.
     * @return The wait step.
     */
    public String getInitialStep() {
      return 'HookRevenantInboundHandlerTest.WaitStep';
    }

    /**
     * @description Ends after the wait step.
     * @param currentStepName The step that completed.
     * @param result The result.
     * @return Null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description Waits for the signal Paid.
   */
  public class WaitStep implements WorkflowStep {
    /**
     * @description Suspends until the signal comes.
     * @param ctx The context.
     * @return SUSPEND, or COMPLETE with the payload.
     */
    public StepResult execute(StepContext ctx) {
      StepContext.Signal paid = ctx.signals().getSignal('Paid');
      return paid.isPresent()
        ? StepResult.complete(null, paid.payload)
        : StepResult.suspend();
    }
  }
}
