/**
 * @description Tests for the queue channel and the dispatch job (AC-OUT-2,
 * AC-OUT-4 to AC-OUT-11, AC-OUT-14).
 */
@IsTest
private class HookDispatchJobTest {
  private static Hook_Subscription__c sub;

  private static Hook_Delivery__c claimed() {
    sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'In_Flight');
    d.Claim_Token__c = 'tok';
    d.Lease_Until__c = Datetime.now().addMinutes(10);
    update d;
    return d;
  }

  private static void runToken(String token) {
    new HookDispatchJob(token).execute(null);
  }

  @IsTest
  static void a2xxDeliversWithSignedStandardHeaders() {
    HookTestSupport.settings();
    HookClock.fixedSeconds = 1700000000L;
    Hook_Delivery__c d = claimed();
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(204, 'ok', null)
    );

    Test.startTest();
    runToken('tok');
    Test.stopTest();

    Hook_Delivery__c after = HookTestSupport.reload(d.Id);
    Assert.areEqual('Delivered', after.Status__c);
    Assert.areEqual(1, after.Attempts__c);
    Assert.areEqual(204, after.Last_Status_Code__c);
    Assert.isNotNull(after.Delivered_At__c);
    Assert.isNull(after.Claim_Token__c);
    Assert.isNull(after.Lease_Until__c);

    HttpRequest req = HookTestSupport.requests[0];
    Assert.areEqual('POST', req.getMethod());
    Assert.areEqual('https://example.com/hooks/s', req.getEndpoint());
    Assert.areEqual('application/json', req.getHeader('Content-Type'));
    Assert.areEqual(after.Event_Id__c, req.getHeader('webhook-id'));
    Assert.areEqual('1700000000', req.getHeader('webhook-timestamp'));
    Assert.areEqual(after.Payload__c, req.getBody());
    String secret = Hook_Secret__c.getInstance('sub_s').Value__c;
    Assert.areEqual(
      HookSigner.standardSignature(
        secret,
        after.Event_Id__c,
        1700000000L,
        after.Payload__c
      ),
      req.getHeader('webhook-signature')
    );
  }

  @IsTest
  static void a500RetriesWithBackoffAndKeepsTheResponse() {
    HookTestSupport.settings();
    HookClock.fixedSeconds = 1700000000L;
    Hook_Delivery__c d = claimed();
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(500, 'e'.repeat(5000), null)
    );

    Test.startTest();
    runToken('tok');
    Test.stopTest();

    Hook_Delivery__c after = HookTestSupport.reload(d.Id);
    Assert.areEqual('Retrying', after.Status__c);
    Assert.areEqual(500, after.Last_Status_Code__c);
    Assert.areEqual(
      Datetime.newInstance(1700000060000L),
      after.Next_Attempt_At__c
    );
    Assert.areEqual(2000, after.Last_Response__c.length(), 'AC-OUT-4');
    Assert.areEqual(
      1,
      [SELECT Consecutive_Failures__c FROM Hook_Subscription__c]
      .Consecutive_Failures__c
    );
  }

  @IsTest
  static void retryAfterIsUsedFor429And503() {
    HookTestSupport.settings();
    HookClock.fixedSeconds = 1700000000L;
    Hook_Delivery__c d = claimed();
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp()
        .add(429, '', new Map<String, String>{ 'Retry-After' => '120' })
    );
    Test.startTest();
    runToken('tok');
    Test.stopTest();
    Assert.areEqual(
      Datetime.newInstance(1700000120000L),
      HookTestSupport.reload(d.Id).Next_Attempt_At__c
    );
  }

  @IsTest
  static void aTimeoutRetries() {
    HookTestSupport.settings();
    Hook_Delivery__c d = claimed();
    Test.setMock(HttpCalloutMock.class, new HookTestSupport.TimeoutHttp());
    Test.startTest();
    runToken('tok');
    Test.stopTest();
    Hook_Delivery__c after = HookTestSupport.reload(d.Id);
    Assert.areEqual('Retrying', after.Status__c);
    Assert.isTrue(
      after.Last_Error__c.contains('Read timed out'),
      after.Last_Error__c
    );
  }

  @IsTest
  static void theLastAttemptFails() {
    HookTestSupport.settings().Max_Attempts__c = 3;
    Hook_Delivery__c d = claimed();
    d.Attempts__c = 2;
    update d;
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(500, '', null)
    );
    Test.startTest();
    runToken('tok');
    Test.stopTest();
    Hook_Delivery__c after = HookTestSupport.reload(d.Id);
    Assert.areEqual('Failed', after.Status__c);
    Assert.areEqual(3, after.Attempts__c);
    Assert.isNull(after.Next_Attempt_At__c);
  }

  @IsTest
  static void theSubscriptionMaxAttemptsWins() {
    HookTestSupport.settings().Max_Attempts__c = 10;
    Hook_Delivery__c d = claimed();
    sub.Max_Attempts__c = 1;
    update sub;
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(500, '', null)
    );
    Test.startTest();
    runToken('tok');
    Test.stopTest();
    Assert.areEqual('Failed', HookTestSupport.reload(d.Id).Status__c);
  }

  @IsTest
  static void a410FailsAndDisablesTheSubscription() {
    HookTestSupport.settings();
    Hook_Delivery__c d = claimed();
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(410, 'gone', null)
    );
    Test.startTest();
    runToken('tok');
    Test.stopTest();
    Assert.areEqual('Failed', HookTestSupport.reload(d.Id).Status__c);
    Hook_Subscription__c after = [
      SELECT Active__c, Disabled_Reason__c
      FROM Hook_Subscription__c
    ];
    Assert.isFalse(after.Active__c);
    Assert.isTrue(
      after.Disabled_Reason__c.contains('410'),
      after.Disabled_Reason__c
    );
  }

  @IsTest
  static void failuresInARowDisable() {
    HookTestSupport.settings().Disable_After_Failures__c = 2;
    claimed();
    sub.Consecutive_Failures__c = 1;
    update sub;
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(503, '', null)
    );
    Test.startTest();
    runToken('tok');
    Test.stopTest();
    Hook_Subscription__c after = [
      SELECT Active__c, Consecutive_Failures__c, Disabled_Reason__c
      FROM Hook_Subscription__c
    ];
    Assert.isFalse(after.Active__c, 'AC-OUT-9');
    Assert.areEqual(2, after.Consecutive_Failures__c);
    Assert.isTrue(
      after.Disabled_Reason__c.contains('2'),
      after.Disabled_Reason__c
    );
  }

  @IsTest
  static void aSuccessResetsTheFailureCount() {
    HookTestSupport.settings();
    claimed();
    sub.Consecutive_Failures__c = 4;
    update sub;
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(200, '', null)
    );
    Test.startTest();
    runToken('tok');
    Test.stopTest();
    Assert.areEqual(
      0,
      [SELECT Consecutive_Failures__c FROM Hook_Subscription__c]
      .Consecutive_Failures__c
    );
  }

  @IsTest
  static void aMissingSecretFailsWithAClearError() {
    HookTestSupport.settings();
    Hook_Delivery__c d = claimed();
    sub.Secret_Name__c = 'not_set';
    update sub;
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(200, '', null)
    );
    Test.startTest();
    runToken('tok');
    Test.stopTest();
    Hook_Delivery__c after = HookTestSupport.reload(d.Id);
    Assert.areEqual('Failed', after.Status__c);
    Assert.isTrue(after.Last_Error__c.contains('secret'), after.Last_Error__c);
    Assert.areEqual(0, HookTestSupport.requests.size(), 'no unsigned callout');
  }

  @IsTest
  static void aRotatedSecretSignsWithBoth() {
    HookTestSupport.settings();
    claimed();
    Hook.rotateSecret('sub_s', 24);
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(200, '', null)
    );
    Test.startTest();
    runToken('tok');
    Test.stopTest();
    Assert.areEqual(
      2,
      HookTestSupport.requests[0]
        .getHeader('webhook-signature')
        .split(' ')
        .size()
    );
  }

  @IsTest
  static void oneJobSendsAtMostTheBatchSizeAndChains() {
    HookTestSupport.settings().Batch_Size__c = 2;
    sub = HookTestSupport.subscription('s', '*');
    List<Hook_Delivery__c> rows = new List<Hook_Delivery__c>();
    for (Integer i = 0; i < 3; i++) {
      Hook_Delivery__c d = HookTestSupport.delivery(sub, 'In_Flight');
      d.Claim_Token__c = 'tok';
      d.Lease_Until__c = Datetime.now().addMinutes(10);
      rows.add(d);
    }
    update rows;
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(200, '', null)
    );

    Test.startTest();
    runToken('tok');
    Assert.areEqual(2, HookTestSupport.requests.size());
    Assert.areEqual(1, HookAsync.deferred.size(), 'a chained job');
    HookDispatchJob next = (HookDispatchJob) HookAsync.deferred[0];
    Hook_Delivery__c left = [
      SELECT Claim_Token__c, Status__c
      FROM Hook_Delivery__c
      WHERE Status__c = 'In_Flight'
    ];
    Assert.areEqual(
      next.token,
      left.Claim_Token__c,
      'the rest has a new claim'
    );
    Assert.areNotEqual('tok', left.Claim_Token__c);
    Test.stopTest();
  }

  @IsTest
  static void theClaimSkipsInactiveLiveAndNotDueRows() {
    HookTestSupport.settings();
    sub = HookTestSupport.subscription('s', '*');
    Hook_Subscription__c off = HookTestSupport.subscription('off', '*');
    Hook_Delivery__c pending = HookTestSupport.delivery(sub, 'Pending');
    Hook_Delivery__c due = HookTestSupport.delivery(sub, 'Retrying');
    due.Next_Attempt_At__c = Datetime.now().addMinutes(-1);
    Hook_Delivery__c later = HookTestSupport.delivery(sub, 'Retrying');
    later.Next_Attempt_At__c = Datetime.now().addMinutes(30);
    Hook_Delivery__c expired = HookTestSupport.delivery(sub, 'In_Flight');
    expired.Claim_Token__c = 'old';
    expired.Lease_Until__c = Datetime.now().addMinutes(-1);
    Hook_Delivery__c live = HookTestSupport.delivery(sub, 'In_Flight');
    live.Claim_Token__c = 'other';
    live.Lease_Until__c = Datetime.now().addMinutes(5);
    Hook_Delivery__c inactive = HookTestSupport.delivery(off, 'Pending');
    Hook_Delivery__c revenant = HookTestSupport.delivery(sub, 'Pending');
    revenant.Channel__c = 'HookRevenantChannel';
    update new List<Hook_Delivery__c>{ due, later, expired, live, revenant };
    off.Active__c = false;
    update off;

    String token = HookQueueChannel.claim(null, 50);

    Set<Id> got = new Map<Id, Hook_Delivery__c>(
        [
          SELECT Id
          FROM Hook_Delivery__c
          WHERE Claim_Token__c = :token AND Status__c = 'In_Flight'
        ]
      )
      .keySet();
    Assert.areEqual(new Set<Id>{ pending.Id, due.Id, expired.Id }, got);
    Assert.isFalse(got.contains(inactive.Id), 'inactive subscription');
    Assert.isNull(HookQueueChannel.claim(null, 50), 'nothing left to claim');
  }

  @IsTest
  static void aShortRetryArmsADelayedClaim() {
    HookTestSupport.settings();
    claimed();
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(500, '', null)
    );
    Test.startTest();
    runToken('tok');
    Assert.areEqual(1, HookAsync.deferred.size());
    Assert.isNull(
      ((HookDispatchJob) HookAsync.deferred[0]).token,
      'a claim job'
    );
    Assert.areEqual(
      1,
      HookAsync.deferredDelays[0],
      'one minute for a 60 s retry'
    );
    Test.stopTest();
  }

  @IsTest
  static void aClaimJobClaimsAndChains() {
    HookTestSupport.settings();
    sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'Pending');
    Test.startTest();
    new HookDispatchJob(null).execute(null);
    Assert.areEqual(1, HookAsync.deferred.size());
    String token = ((HookDispatchJob) HookAsync.deferred[0]).token;
    Assert.areEqual(token, HookTestSupport.reload(d.Id).Claim_Token__c);
    Test.stopTest();
  }

  @IsTest
  static void sendRunsTheJobAfterCommit() {
    HookTestSupport.settings();
    HookTestSupport.subscription('s', '*');
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(200, '', null)
    );
    Test.startTest();
    Hook.send('order.paid', null);
    Test.stopTest();
    Assert.areEqual(
      'Delivered',
      [SELECT Status__c FROM Hook_Delivery__c].Status__c
    );
  }

  @IsTest
  static void redeliverResetsAndDispatches() {
    HookTestSupport.settings();
    sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'Failed');
    d.Attempts__c = 5;
    update d;
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(200, '', null)
    );
    Test.startTest();
    Hook.redeliver(new Set<Id>{ d.Id });
    Test.stopTest();
    Hook_Delivery__c after = HookTestSupport.reload(d.Id);
    Assert.areEqual('Delivered', after.Status__c);
    Assert.areEqual(1, after.Attempts__c);
    Assert.areEqual(1, after.Generation__c);
  }

  @IsTest
  static void aFailedJobReleasesItsRows() {
    HookTestSupport.settings().Max_Attempts__c = 2;
    Hook_Delivery__c retry = claimed();
    Hook_Delivery__c last = HookTestSupport.delivery(sub, 'In_Flight');
    last.Claim_Token__c = 'tok';
    last.Attempts__c = 1;
    Hook_Delivery__c other = HookTestSupport.delivery(sub, 'In_Flight');
    other.Claim_Token__c = 'other';
    update new List<Hook_Delivery__c>{ last, other };

    Test.startTest();
    new HookDispatchFinalizer('tok').execute(new FailedContext());
    Test.stopTest();

    Hook_Delivery__c afterRetry = HookTestSupport.reload(retry.Id);
    Assert.areEqual('Retrying', afterRetry.Status__c);
    Assert.areEqual(1, afterRetry.Attempts__c);
    Assert.isNull(afterRetry.Claim_Token__c);
    Assert.isNotNull(afterRetry.Next_Attempt_At__c);
    Assert.isTrue(
      afterRetry.Last_Error__c.contains('Apex CPU time limit'),
      afterRetry.Last_Error__c
    );
    Assert.areEqual('Failed', HookTestSupport.reload(last.Id).Status__c);
    Assert.areEqual(
      'other',
      HookTestSupport.reload(other.Id).Claim_Token__c,
      'other jobs keep their rows'
    );
  }

  @IsTest
  static void aSuccessfulJobLeavesItsRows() {
    HookTestSupport.settings();
    Hook_Delivery__c d = claimed();
    new HookDispatchFinalizer('tok').execute(new FailedContext().succeeded());
    Assert.areEqual('In_Flight', HookTestSupport.reload(d.Id).Status__c);
  }

  /**
   * @description A finalizer context for a failed or a good job.
   */
  private class FailedContext implements FinalizerContext {
    private ParentJobResult result = ParentJobResult.UNHANDLED_EXCEPTION;

    /**
     * @description Makes the job good.
     * @return This context.
     */
    public FailedContext succeeded() {
      result = ParentJobResult.SUCCESS;
      return this;
    }

    /**
     * @description Gives no job Id.
     * @return Null.
     */
    public Id getAsyncApexJobId() {
      return null;
    }

    /**
     * @description Gives the error of a failed job.
     * @return The error, or null.
     */
    public Exception getException() {
      return result == ParentJobResult.SUCCESS
        ? null
        : new HookException('Apex CPU time limit exceeded');
    }

    /**
     * @description Gives a request Id.
     * @return The Id.
     */
    public String getRequestId() {
      return 'req';
    }

    /**
     * @description Gives the job result.
     * @return The result.
     */
    public ParentJobResult getResult() {
      return result;
    }
  }

  @IsTest
  static void aRowWithAShortLeaseWaitsForTheNextClaim() {
    HookTestSupport.settings();
    Hook_Delivery__c d = claimed();
    d.Lease_Until__c = Datetime.now().addSeconds(60);
    update d;
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp().add(200, '', null)
    );
    Test.startTest();
    runToken('tok');
    Assert.areEqual(
      0,
      HookTestSupport.requests.size(),
      'no send near the end of the lease'
    );
    Assert.areEqual(
      1,
      HookAsync.deferred.size(),
      'the next job claims it with a new lease'
    );
    Test.stopTest();
  }

  @IsTest
  static void aSendInsertsClaimedRowsWithOneStatement() {
    HookTestSupport.settings();
    HookTestSupport.subscription('s', '*');
    Integer before = Limits.getDmlStatements();
    Hook.send('order.paid', null);
    Assert.areEqual(1, Limits.getDmlStatements() - before);
    Hook_Delivery__c d = [
      SELECT Status__c, Claim_Token__c, Lease_Until__c
      FROM Hook_Delivery__c
    ];
    Assert.areEqual('In_Flight', d.Status__c);
    Assert.isNotNull(d.Claim_Token__c);
    Assert.isNotNull(d.Lease_Until__c);
  }

  @IsTest
  static void retryAfterOn503IsUsedAndCapped() {
    HookTestSupport.settings().Max_Delay_Seconds__c = 100;
    HookClock.fixedSeconds = 1700000000L;
    Hook_Delivery__c d = claimed();
    Test.setMock(
      HttpCalloutMock.class,
      new HookTestSupport.MockHttp()
        .add(503, '', new Map<String, String>{ 'Retry-After' => '7200' })
    );
    Test.startTest();
    runToken('tok');
    Test.stopTest();
    Assert.areEqual(
      Datetime.newInstance(1700000100000L),
      HookTestSupport.reload(d.Id).Next_Attempt_At__c,
      'Retry-After is capped by Max_Delay_Seconds__c'
    );
  }
}
