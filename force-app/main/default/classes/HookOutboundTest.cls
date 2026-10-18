/**
 * @description Tests for Hook.send and the outbox (AC-OUT-1, AC-OUT-2,
 * AC-OUT-3, AC-OUT-13).
 */
@IsTest
private class HookOutboundTest {
  @IsTest
  static void sendMakesOneDeliveryForEachMatchingSubscription() {
    HookTestSupport.settings();
    Hook_Subscription__c all = HookTestSupport.subscription('all', '*');
    Hook_Subscription__c exact = HookTestSupport.subscription(
      'exact',
      'order.paid'
    );
    Hook_Subscription__c prefix = HookTestSupport.subscription(
      'prefix',
      'invoice.*; order.*'
    );
    Hook_Subscription__c other = HookTestSupport.subscription(
      'other',
      'invoice.paid'
    );
    Hook_Subscription__c off = HookTestSupport.subscription('off', '*');
    off.Active__c = false;
    update off;

    Test.startTest();
    String eventId = Hook.send(
      'Order.Paid',
      new Map<String, Object>{ 'orderId' => 'o-1' }
    );
    Assert.areEqual(
      0,
      Limits.getCallouts(),
      'no callout in the caller transaction'
    );
    Assert.areEqual(
      1,
      Limits.getQueueableJobs(),
      'one job for the transaction'
    );
    Test.stopTest();

    Assert.isTrue(eventId.startsWith('msg_'));
    Set<Id> matched = new Set<Id>();
    for (Hook_Delivery__c d : [
      SELECT Subscription__c, Event_Id__c, Event_Type__c, Channel__c
      FROM Hook_Delivery__c
    ]) {
      matched.add(d.Subscription__c);
      Assert.areEqual(eventId, d.Event_Id__c);
      Assert.areEqual('Order.Paid', d.Event_Type__c);
      Assert.areEqual(HookQueueChannel.NAME, d.Channel__c);
    }
    Assert.areEqual(new Set<Id>{ all.Id, exact.Id, prefix.Id }, matched);
    Assert.isFalse(matched.contains(other.Id));
  }

  @IsTest
  static void thePayloadIsTheStandardEnvelope() {
    HookTestSupport.settings();
    HookTestSupport.subscription('all', '*');
    HookClock.fixedSeconds = 1700000000L;
    String eventId = Hook.send(
      'order.paid',
      new Map<String, Object>{ 'n' => 1 },
      'evt_given'
    );
    Assert.areEqual('evt_given', eventId);
    Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
      [SELECT Payload__c FROM Hook_Delivery__c].Payload__c
    );
    Assert.areEqual('evt_given', body.get('id'));
    Assert.areEqual('order.paid', body.get('type'));
    Assert.areEqual('2023-11-14T22:13:20.000Z', body.get('timestamp'));
    Assert.areEqual(1, ((Map<String, Object>) body.get('data')).get('n'));
  }

  @IsTest
  static void theSameEventIdTwiceMakesOneDelivery() {
    HookTestSupport.settings();
    HookTestSupport.subscription('all', '*');
    Hook.send('order.paid', null, 'evt_1');
    Hook.send('order.paid', null, 'evt_1');
    Assert.areEqual(1, [SELECT COUNT() FROM Hook_Delivery__c]);
  }

  @IsTest
  static void bulkSendUsesFewStatements() {
    HookTestSupport.settings();
    HookTestSupport.subscription('a', '*');
    HookTestSupport.subscription('b', 'order.*');
    List<HookEvent> events = new List<HookEvent>();
    for (Integer i = 0; i < 200; i++) {
      events.add(
        new HookEvent('order.paid', new Map<String, Object>{ 'i' => i })
      );
    }
    Test.startTest();
    Integer queriesBefore = Limits.getQueries();
    Integer dmlBefore = Limits.getDmlStatements();
    List<String> ids = Hook.send(events);
    Assert.isTrue(Limits.getQueries() - queriesBefore <= 2, 'queries');
    Assert.isTrue(Limits.getDmlStatements() - dmlBefore <= 3, 'DML statements');
    Assert.areEqual(1, Limits.getQueueableJobs());
    Test.stopTest();
    Assert.areEqual(200, ids.size());
    Assert.areEqual(400, [SELECT COUNT() FROM Hook_Delivery__c]);
  }

  @IsTest
  static void noSubscriptionGivesAnIdAndNoRow() {
    HookTestSupport.settings();
    Assert.isNotNull(Hook.send('order.paid', null));
    Assert.areEqual(0, [SELECT COUNT() FROM Hook_Delivery__c]);
    Assert.areEqual(0, Limits.getQueueableJobs());
  }

  @IsTest
  static void aLargePayloadThrows() {
    HookTestSupport.settings();
    HookTestSupport.subscription('all', '*');
    try {
      Hook.send('order.paid', 'x'.repeat(131072));
      Assert.fail('Expected a HookException');
    } catch (HookException e) {
      Assert.isTrue(e.getMessage().contains('131072'), e.getMessage());
    }
  }

  @IsTest
  static void aBlankTypeThrows() {
    try {
      Hook.send(' ', null);
      Assert.fail('Expected a HookException');
    } catch (HookException e) {
      Assert.isTrue(e.getMessage().contains('type'), e.getMessage());
    }
  }

  @IsTest
  static void theSubscriptionChannelAndTheDefaultChannelAreUsed() {
    HookTestSupport.settings()
      .Default_Channel__c = 'HookTestSupport.RecordingChannel';
    Hook_Subscription__c custom = HookTestSupport.subscription('custom', '*');
    Hook_Subscription__c bad = HookTestSupport.subscription('bad', '*');
    bad.Channel__c = 'NoSuchChannel';
    update bad;

    Hook.send('order.paid', null);

    Hook_Delivery__c viaDefault = [
      SELECT Id, Channel__c
      FROM Hook_Delivery__c
      WHERE Subscription__c = :custom.Id
    ];
    Assert.areEqual('HookTestSupport.RecordingChannel', viaDefault.Channel__c);
    Assert.areEqual(new List<Id>{ viaDefault.Id }, HookTestSupport.dispatched);
    Hook_Delivery__c failed = [
      SELECT Status__c, Last_Error__c
      FROM Hook_Delivery__c
      WHERE Subscription__c = :bad.Id
    ];
    Assert.areEqual('Failed', failed.Status__c);
    Assert.isTrue(
      failed.Last_Error__c.contains('NoSuchChannel'),
      failed.Last_Error__c
    );
  }

  @IsTest
  static void hookEventKeepsItsValues() {
    HookEvent e = new HookEvent('a.b', 5).withId('evt_x');
    Assert.areEqual('a.b', e.eventType);
    Assert.areEqual(5, e.payload);
    Assert.areEqual('evt_x', e.eventId);
  }

  @IsTest
  static void anHttpEndpointIsRejected() {
    Hook_Subscription__c sub = new Hook_Subscription__c(
      Name = 'plain',
      Endpoint__c = 'http://example.com',
      Event_Types__c = '*',
      Active__c = true
    );
    Database.SaveResult sr = Database.insert(sub, false);
    Assert.isFalse(sr.isSuccess(), 'AC-SEC-4');
    sub.Endpoint__c = 'callout:My_Credential/hooks';
    Assert.isTrue(Database.insert(sub, false).isSuccess());
  }
}
