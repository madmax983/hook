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
  static void anInactiveSubscriptionPausesTheRow() {
    HookTestSupport.settings();
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'In_Flight');
    d.Claim_Token__c = 'tok';
    update d;
    sub.Active__c = false;
    update sub;
    HookDelivery.Attempt attempt = HookDelivery.prepare(d.Id);
    HookDelivery.Outcome outcome = attempt.send();
    Assert.areEqual('PAUSED', outcome.kind);
    Assert.isFalse(outcome.isRetryable());
    attempt.record(null);
    Hook_Delivery__c after = HookTestSupport.reload(d.Id);
    Assert.areEqual(
      'Pending',
      after.Status__c,
      'the row waits for the subscription'
    );
    Assert.areEqual(0, after.Attempts__c, 'a pause is not an attempt');
    Assert.isNull(after.Claim_Token__c);
  }

  @IsTest
  static void recordSkipsARowThatWasRedeliveredAfterTheRead() {
    HookTestSupport.settings();
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'Pending');
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(500, '', null)
    );
    Test.startTest();
    HookDelivery.Attempt attempt = HookDelivery.prepare(d.Id);
    attempt.send();
    update new Hook_Delivery__c(
      Id = d.Id,
      Generation__c = 1,
      Status__c = 'Pending'
    );
    attempt.record(null);
    Test.stopTest();
    Hook_Delivery__c after = HookTestSupport.reload(d.Id);
    Assert.areEqual('Pending', after.Status__c, 'the redelivery wins');
    Assert.areEqual(0, after.Attempts__c);
  }

  @IsTest
  static void recordDoesNotEnableADisabledSubscription() {
    HookTestSupport.settings();
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'Pending');
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(200, '', null)
    );
    Test.startTest();
    HookDelivery.Attempt attempt = HookDelivery.prepare(d.Id);
    attempt.send();
    update new Hook_Subscription__c(
      Id = sub.Id,
      Active__c = false,
      Disabled_Reason__c = 'admin'
    );
    attempt.record(null);
    Test.stopTest();
    Hook_Subscription__c after = [
      SELECT Active__c, Disabled_Reason__c
      FROM Hook_Subscription__c
    ];
    Assert.isFalse(after.Active__c);
    Assert.areEqual('admin', after.Disabled_Reason__c);
  }

  @IsTest
  static void anErrorThatIsNotACalloutErrorGivesAConfigOutcome() {
    HookTestSupport.settings();
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'Pending');
    HookDelivery.transport = new BrokenTransport();
    HookDelivery.Outcome outcome = HookDelivery.prepare(d.Id).send();
    Assert.areEqual('CONFIG', outcome.kind);
    Assert.isTrue(outcome.error.contains('could not send'), outcome.error);
  }

  /**
   * @description A transport that fails with an error that is not a CalloutException.
   */
  private class BrokenTransport implements HookTransport {
    /**
     * @description Throws.
     * @param req The request.
     * @return Never.
     */
    public HttpResponse send(HttpRequest req) {
      throw new HookException('broken');
    }
  }

  @IsTest
  static void retryAfterAcceptsSecondsAndHttpDates() {
    HookClock.fixedSeconds = 1700000000L;
    Assert.areEqual(120, HookRetryAfter.seconds('120'));
    Assert.areEqual(
      60,
      HookRetryAfter.seconds('Tue, 14 Nov 2023 22:14:20 GMT')
    );
    Assert.isNull(HookRetryAfter.seconds('soon'));
    Assert.isNull(HookRetryAfter.seconds(null));
    Assert.isNull(HookRetryAfter.seconds('0'));
    Assert.areEqual(86400, HookRetryAfter.seconds('99999999999'));
  }
}
