/**
 * @description Tests for the HookDelivery attempt API that channels use.
 */
@IsTest
private class HookDeliveryTest {
  @IsTest
  static void prepareSendAndRecordADelivery() {
    HookTestSupport.settings().Max_Attempts__c = 4;
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'Pending');
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(201, 'made', null)
    );

    Test.startTest();
    HookDelivery.Attempt attempt = HookDelivery.prepare(d.Id);
    Assert.areEqual(d.Id, attempt.deliveryId);
    Assert.areEqual(0, attempt.attempts);
    Assert.areEqual(4, attempt.maxAttempts);
    Assert.isFalse(attempt.isDelivered());
    HookDelivery.Outcome outcome = attempt.send();
    attempt.record(null);
    Test.stopTest();

    Assert.areEqual('DELIVERED', outcome.kind);
    Assert.isTrue(outcome.isDelivered());
    Assert.isFalse(outcome.isRetryable());
    Assert.areEqual(201, outcome.statusCode);
    Assert.isNull(outcome.error);
    Hook_Delivery__c after = HookTestSupport.reload(d.Id);
    Assert.areEqual('Delivered', after.Status__c);
    Assert.areEqual('made', after.Last_Response__c);
    Assert.isTrue(HookDelivery.prepare(d.Id).isDelivered());
  }

  @IsTest
  static void recordWithATimeRetriesAndWithNullFails() {
    HookTestSupport.settings();
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c a = HookTestSupport.delivery(sub, 'Pending');
    Hook_Delivery__c b = HookTestSupport.delivery(sub, 'Pending');
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp()
        .add(503, '', new Map<String, String>{ 'Retry-After' => '30' })
    );
    Datetime next = Datetime.now().addMinutes(3);

    Test.startTest();
    HookDelivery.Attempt first = HookDelivery.prepare(a.Id);
    HookDelivery.Outcome outcome = first.send();
    HookDelivery.Attempt second = HookDelivery.prepare(b.Id);
    second.send();
    first.record(next);
    second.record(null);
    Test.stopTest();

    Assert.areEqual('RETRY', outcome.kind);
    Assert.isTrue(outcome.isRetryable());
    Assert.areEqual(30, outcome.retryAfterSeconds);
    Hook_Delivery__c afterA = HookTestSupport.reload(a.Id);
    Assert.areEqual('Retrying', afterA.Status__c);
    Assert.areEqual(next, afterA.Next_Attempt_At__c);
    Assert.areEqual('Failed', HookTestSupport.reload(b.Id).Status__c);
  }

  @IsTest
  static void prepareGivesNullForAMissingRow() {
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'Pending');
    Id id = d.Id;
    delete d;
    Assert.isNull(HookDelivery.prepare(id));
  }

  @IsTest
  static void anInactiveSubscriptionGivesAConfigOutcome() {
    HookTestSupport.settings();
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'Pending');
    sub.Active__c = false;
    update sub;
    HookDelivery.Outcome outcome = HookDelivery.prepare(d.Id).send();
    Assert.areEqual('CONFIG', outcome.kind);
    Assert.isTrue(outcome.error.contains('not active'), outcome.error);
  }

  @IsTest
  static void retryAfterAcceptsSecondsAndHttpDates() {
    HookClock.fixedSeconds = 1700000000L;
    Assert.areEqual(120, HookDelivery.retryAfterSeconds('120'));
    Assert.areEqual(
      60,
      HookDelivery.retryAfterSeconds('Tue, 14 Nov 2023 22:14:20 GMT')
    );
    Assert.isNull(HookDelivery.retryAfterSeconds('soon'));
    Assert.isNull(HookDelivery.retryAfterSeconds(null));
    Assert.isNull(HookDelivery.retryAfterSeconds('0'));
    Assert.areEqual(86400, HookDelivery.retryAfterSeconds('99999999999'));
  }
}
