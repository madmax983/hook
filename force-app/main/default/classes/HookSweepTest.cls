/**
 * @description Tests for HookSweep (AC-SW-1, AC-SW-2, AC-SW-3).
 */
@IsTest
private class HookSweepTest {
  private static Hook_Inbound_Event__c inbound(
    String status,
    Integer ageMinutes
  ) {
    Hook_Inbound_Event__c rec = new Hook_Inbound_Event__c(
      Endpoint__c = 'e',
      Event_Id__c = 'id-' + status + ageMinutes,
      Dedup_Key__c = 'e:id-' + status + ageMinutes,
      Body__c = '{}',
      Status__c = status,
      Attempts__c = 0,
      Received_At__c = Datetime.now().addMinutes(-ageMinutes),
      Dispatched_At__c = Datetime.now().addMinutes(-ageMinutes)
    );
    insert rec;
    return rec;
  }

  @IsTest
  static void theSweepClaimsDueDeliveries() {
    HookTestSupport.settings();
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    HookTestSupport.delivery(sub, 'Pending');
    Test.startTest();
    HookSweep.run();
    Assert.areEqual(1, HookAsync.deferred.size(), 'a claim job');
    Test.stopTest();
  }

  @IsTest
  static void theSweepStartsNoJobWhenNothingIsDue() {
    HookTestSupport.settings();
    HookSweep.run();
    Assert.areEqual(0, HookAsync.deferred.size());
  }

  @IsTest
  static void theSweepPublishesDueAndStaleInbound() {
    HookTestSupport.settings();
    HookTestSupport.endpoint('e', 'NONE');
    Hook_Inbound_Event__c stale = inbound('Pending', 10);
    Hook_Inbound_Event__c fresh = inbound('Pending', 0);
    Hook_Inbound_Event__c due = inbound('Retrying', 1);
    due.Next_Attempt_At__c = Datetime.now().addMinutes(-1);
    due.Dispatched_At__c = Datetime.now().addMinutes(-30);
    Hook_Inbound_Event__c later = inbound('Retrying', 2);
    later.Next_Attempt_At__c = Datetime.now().addMinutes(30);
    update new List<Hook_Inbound_Event__c>{ due, later };

    Test.startTest();
    HookSweep.run();
    Test.stopTest();

    Map<Id, Hook_Inbound_Event__c> rows = new Map<Id, Hook_Inbound_Event__c>(
      [SELECT Status__c FROM Hook_Inbound_Event__c]
    );
    Assert.areEqual('Processed', rows.get(stale.Id).Status__c);
    Assert.areEqual('Processed', rows.get(due.Id).Status__c);
    Assert.areEqual('Pending', rows.get(fresh.Id).Status__c);
    Assert.areEqual('Retrying', rows.get(later.Id).Status__c);
  }

  @IsTest
  static void aStalePendingRowWithNoAttemptsLeftFails() {
    HookTestSupport.settings().Max_Attempts__c = 2;
    HookTestSupport.endpoint('e', 'NONE');
    Hook_Inbound_Event__c stale = inbound('Pending', 10);
    stale.Attempts__c = 2;
    update stale;
    HookSweep.run();
    Hook_Inbound_Event__c after = [
      SELECT Status__c, Last_Error__c
      FROM Hook_Inbound_Event__c
    ];
    Assert.areEqual('Failed', after.Status__c);
    Assert.isNotNull(after.Last_Error__c);
  }

  @IsTest
  static void theSweepDeletesOldDoneRows() {
    HookTestSupport.settings().Retention_Days__c = 7;
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c oldDone = HookTestSupport.delivery(sub, 'Delivered');
    oldDone.Delivered_At__c = Datetime.now().addDays(-8);
    Hook_Delivery__c newDone = HookTestSupport.delivery(sub, 'Delivered');
    newDone.Delivered_At__c = Datetime.now().addDays(-1);
    Hook_Delivery__c oldFailed = HookTestSupport.delivery(sub, 'Failed');
    update new List<Hook_Delivery__c>{ oldDone, newDone };
    Hook_Inbound_Event__c oldIn = inbound('Processed', 0);
    oldIn.Processed_At__c = Datetime.now().addDays(-8);
    update oldIn;

    HookSweep.run();

    Set<Id> left = new Map<Id, Hook_Delivery__c>(
        [SELECT Id FROM Hook_Delivery__c]
      )
      .keySet();
    Assert.areEqual(new Set<Id>{ newDone.Id, oldFailed.Id }, left);
    Assert.areEqual(0, [SELECT COUNT() FROM Hook_Inbound_Event__c]);
  }

  @IsTest
  static void scheduleMakesFourJobsAndUnscheduleRemovesThem() {
    Test.startTest();
    Hook.scheduleSweep();
    Hook.scheduleSweep();
    Assert.areEqual(
      4,
      [
        SELECT COUNT()
        FROM CronTrigger
        WHERE CronJobDetail.Name LIKE 'Hook Sweep%'
      ]
    );
    Hook.unscheduleSweep();
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM CronTrigger
        WHERE CronJobDetail.Name LIKE 'Hook Sweep%'
      ]
    );
    Test.stopTest();
  }

  @IsTest
  static void theSchedulableRunsTheSweep() {
    HookTestSupport.settings();
    Test.startTest();
    System.schedule('Hook Sweep test', '0 0 0 1 1 ? 2099', new HookSweep());
    Test.stopTest();
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM CronTrigger
        WHERE CronJobDetail.Name = 'Hook Sweep test'
      ]
    );
  }

  @IsTest
  static void aFailedPublishIsPublishedAgainWithNoAttempt() {
    HookTestSupport.settings();
    HookTestSupport.endpoint('e', 'NONE');
    Hook_Inbound_Event__c rec = inbound('Pending', 0);
    rec.Dispatched_At__c = null;
    update rec;
    Test.startTest();
    HookSweep.run();
    Test.stopTest();
    Hook_Inbound_Event__c after = [
      SELECT Status__c, Attempts__c
      FROM Hook_Inbound_Event__c
    ];
    Assert.areEqual('Processed', after.Status__c);
    Assert.areEqual(1, after.Attempts__c, 'only the handler attempt counts');
  }

  @IsTest
  static void aLostRetryCountsAnAttempt() {
    HookTestSupport.settings().Max_Attempts__c = 3;
    HookTestSupport.endpoint('e', 'NONE');
    Hook_Inbound_Event__c rec = inbound('Retrying', 30);
    rec.Attempts__c = 2;
    rec.Next_Attempt_At__c = Datetime.now().addMinutes(-40);
    update rec;
    HookSweep.run();
    Hook_Inbound_Event__c after = [
      SELECT Status__c, Attempts__c
      FROM Hook_Inbound_Event__c
    ];
    Assert.areEqual(
      'Failed',
      after.Status__c,
      'the dispatch after the due time had no result'
    );
    Assert.areEqual(3, after.Attempts__c);
  }

  @IsTest
  static void theSweepClaimsAnExpiredLease() {
    HookTestSupport.settings();
    Hook_Subscription__c sub = HookTestSupport.subscription('s', '*');
    Hook_Delivery__c d = HookTestSupport.delivery(sub, 'In_Flight');
    d.Claim_Token__c = 'dead';
    d.Lease_Until__c = Datetime.now().addMinutes(-1);
    update d;
    Test.startTest();
    HookSweep.run();
    Assert.areEqual(1, HookAsync.deferred.size());
    ((HookDispatchJob) HookAsync.deferred[0]).execute(null);
    Assert.areNotEqual('dead', HookTestSupport.reload(d.Id).Claim_Token__c);
    Test.stopTest();
  }

  @IsTest
  static void theScheduleRunsAtMinutes0And15And30And45() {
    Test.startTest();
    Hook.scheduleSweep();
    Set<String> crons = new Set<String>();
    for (CronTrigger ct : [
      SELECT CronExpression
      FROM CronTrigger
      WHERE CronJobDetail.Name LIKE 'Hook Sweep%'
    ]) {
      crons.add(ct.CronExpression);
    }
    Test.stopTest();
    Assert.areEqual(
      new Set<String>{
        '0 0 * * * ?',
        '0 15 * * * ?',
        '0 30 * * * ?',
        '0 45 * * * ?'
      },
      crons
    );
  }
}
