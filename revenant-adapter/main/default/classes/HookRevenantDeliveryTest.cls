/**
 * @description Tests for the Revenant delivery workflow and its step (AC-RV-2).
 */
@IsTest
private class HookRevenantDeliveryTest {
  private static Hook_Delivery__c row;

  private static StepContext context(Integer attempt) {
    HookTestSupport.settings().Max_Attempts__c = 3;
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    sub.Channel__c = 'HookRevenantChannel';
    update sub;
    row = HookTestSupport.delivery(sub, 'Pending');
    row.Channel__c = 'HookRevenantChannel';
    update row;
    return new StepContextTestBuilder()
      .workflowName(HookRevenantDelivery.WORKFLOW)
      .stepName(HookRevenantDelivery.STEP)
      .workflowInput(new Map<String, Object>{ 'deliveryId' => row.Id })
      .attempt(attempt)
      .maxAttempts(3)
      .build();
  }

  private static StepResult run(StepContext ctx, HttpCalloutMock mock) {
    Test.setMock(HttpCalloutMock.class, mock);
    Test.startTest();
    StepResult result = new HookRevenantDelivery.DeliverStep().execute(ctx);
    Test.stopTest();
    return result;
  }

  @IsTest
  static void a2xxCompletes() {
    StepContext ctx = context(1);
    StepResult result = run(
      ctx,
      new HookTestSupport.MockHttp().add(200, '', null)
    );
    Assert.areEqual(StepResult.ActionType.COMPLETE, result.directive().action);
    Assert.areEqual('Delivered', HookTestSupport.reload(row.Id).Status__c);
    Assert.areEqual(
      row.Event_Id__c,
      HookTestSupport.requests[0].getHeader('webhook-id')
    );
  }

  @IsTest
  static void a429WithRetryAfterSleeps() {
    StepContext ctx = context(1);
    StepResult result = run(
      ctx,
      new HookTestSupport.MockHttp()
        .add(429, '', new Map<String, String>{ 'Retry-After' => '90' })
    );
    Assert.areEqual(StepResult.ActionType.SLEEP, result.directive().action);
    Assert.areEqual(90, result.directive().sleepDurationSeconds);
    Assert.areEqual('Retrying', HookTestSupport.reload(row.Id).Status__c);
  }

  @IsTest
  static void a500Retries() {
    StepContext ctx = context(1);
    StepResult result = run(
      ctx,
      new HookTestSupport.MockHttp().add(500, '', null)
    );
    Assert.areEqual(StepResult.ActionType.RETRY, result.directive().action);
    Assert.areEqual(3, result.directive().retry.policy.maximumAttempts);
    Hook_Delivery__c after = HookTestSupport.reload(row.Id);
    Assert.areEqual('Retrying', after.Status__c);
    Assert.isNotNull(after.Next_Attempt_At__c);
  }

  @IsTest
  static void theFinalAttemptFails() {
    StepContext ctx = context(3);
    StepResult result = run(
      ctx,
      new HookTestSupport.MockHttp().add(500, '', null)
    );
    Assert.areEqual(StepResult.ActionType.FAIL, result.directive().action);
    Assert.areEqual('Failed', HookTestSupport.reload(row.Id).Status__c);
  }

  @IsTest
  static void theHookAttemptCountAlsoEndsTheRetries() {
    StepContext ctx = context(1);
    row.Attempts__c = 2;
    update row;
    StepResult result = run(
      ctx,
      new HookTestSupport.MockHttp().add(500, '', null)
    );
    Assert.areEqual(StepResult.ActionType.FAIL, result.directive().action);
    Assert.areEqual('Failed', HookTestSupport.reload(row.Id).Status__c);
  }

  @IsTest
  static void a410Fails() {
    StepContext ctx = context(1);
    StepResult result = run(
      ctx,
      new HookTestSupport.MockHttp().add(410, '', null)
    );
    Assert.areEqual(StepResult.ActionType.FAIL, result.directive().action);
    Assert.isFalse([SELECT Active__c FROM Hook_Subscription__c].Active__c);
  }

  @IsTest
  static void aDeliveredRowCompletesWithNoCallout() {
    StepContext ctx = context(1);
    row.Status__c = 'Delivered';
    update row;
    StepResult result = run(
      ctx,
      new HookTestSupport.MockHttp().add(500, '', null)
    );
    Assert.areEqual(StepResult.ActionType.COMPLETE, result.directive().action);
    Assert.areEqual(0, HookTestSupport.requests.size());
  }

  @IsTest
  static void aMissingRowFails() {
    StepContext ctx = context(1);
    delete row;
    StepResult result = run(
      ctx,
      new HookTestSupport.MockHttp().add(200, '', null)
    );
    Assert.areEqual(StepResult.ActionType.FAIL, result.directive().action);
  }

  @IsTest
  static void theStepIsACalloutStep() {
    Object step = new HookRevenantDelivery.DeliverStep();
    Assert.isTrue(step instanceof CalloutStep);
    Assert.isTrue(step instanceof AutoRetryConfigurable);
    Assert.isNotNull(((AutoRetryConfigurable) step).getAutoRetryPolicy());
  }

  @IsTest
  static void theWorkflowHasOneStep() {
    HookRevenantDelivery.DeliveryWorkflow wf = new HookRevenantDelivery.DeliveryWorkflow();
    Assert.areEqual(
      new List<String>{ HookRevenantDelivery.STEP },
      wf.getSteps()
    );
    Assert.areEqual(HookRevenantDelivery.STEP, wf.getInitialStep());
    Assert.isNull(
      wf.getNextStep(HookRevenantDelivery.STEP, StepResult.complete(null, null))
    );
  }

  @IsTest
  static void theWorkflowDeliversEndToEnd() {
    HookTestSupport.settings();
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    sub.Channel__c = 'HookRevenantChannel';
    update sub;
    HookDelivery.transport = new HookTestSupport.FakeTransport(
      new List<Integer>{ 503, 200 }
    );

    Test.startTest();
    Hook.send('order.paid', new Map<String, Object>{ 'n' => 1 });
    Hook_Delivery__c d = [SELECT Id, Generation__c FROM Hook_Delivery__c];
    WorkflowEngine.WorkflowStatus status = WorkflowStatusRead.getStatus(
      HookRevenantChannel.correlationKey(d.Id, 0)
    );
    WorkflowTestHarness.Result done = new WorkflowTestHarness(status.instanceId)
      .drive();
    Test.stopTest();

    Assert.areEqual('Completed', done.status);
    Hook_Delivery__c after = HookTestSupport.reload(d.Id);
    Assert.areEqual('Delivered', after.Status__c);
    Assert.areEqual(2, after.Attempts__c);
  }

  @IsTest
  static void a503WithRetryAfterSleeps() {
    StepContext ctx = context(1);
    StepResult result = run(
      ctx,
      new HookTestSupport.MockHttp()
        .add(503, '', new Map<String, String>{ 'Retry-After' => '45' })
    );
    Assert.areEqual(StepResult.ActionType.SLEEP, result.directive().action);
    Assert.areEqual(45, result.directive().sleepDurationSeconds);
  }

  @IsTest
  static void aMissingSecretFails() {
    StepContext ctx = context(1);
    update new Hook_Subscription__c(
      Id = row.Subscription__c,
      Secret_Name__c = 'not_set'
    );
    StepResult result = run(
      ctx,
      new HookTestSupport.MockHttp().add(200, '', null)
    );
    Assert.areEqual(StepResult.ActionType.FAIL, result.directive().action);
    Assert.areEqual(0, HookTestSupport.requests.size());
  }

  @IsTest
  static void anInactiveSubscriptionFailsAndTheRowWaits() {
    StepContext ctx = context(1);
    update new Hook_Subscription__c(
      Id = row.Subscription__c,
      Active__c = false
    );
    StepResult result = run(
      ctx,
      new HookTestSupport.MockHttp().add(200, '', null)
    );
    Assert.areEqual(StepResult.ActionType.FAIL, result.directive().action);
    Assert.areEqual('Pending', HookTestSupport.reload(row.Id).Status__c);
  }
}
