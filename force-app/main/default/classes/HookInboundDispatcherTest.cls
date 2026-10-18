/**
 * @description Tests for the inbound dispatcher (AC-IN-7, AC-IN-8, AC-IN-9,
 * AC-IN-12) and HookInboundEvent.
 */
@IsTest
private class HookInboundDispatcherTest {
  private static Hook_Inbound_Event__c event(
    String endpoint,
    String eventId,
    String body
  ) {
    Hook_Inbound_Event__c rec = new Hook_Inbound_Event__c(
      Endpoint__c = endpoint,
      Event_Id__c = eventId,
      Event_Type__c = 'thing.made',
      Dedup_Key__c = endpoint + ':' + eventId,
      Body__c = body,
      Headers__c = '{"x-trace":"t-1"}',
      Status__c = 'Pending',
      Attempts__c = 0,
      Received_At__c = Datetime.now()
    );
    insert rec;
    return rec;
  }

  private static Hook_Inbound_Event__c reload(Id id) {
    return [
      SELECT
        Status__c,
        Attempts__c,
        Next_Attempt_At__c,
        Last_Error__c,
        Processed_At__c
      FROM Hook_Inbound_Event__c
      WHERE Id = :id
    ];
  }

  @IsTest
  static void theHandlerGetsTheEventAndTheRowIsProcessed() {
    HookTestSupport.settings();
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('e', 'NONE');
    ep.Handler_Config__c = '{"flow":"X"}';
    Hook_Inbound_Event__c rec = event(
      'e',
      'id-1',
      '{"data":{"items":[{"sku":"A-1"}]}}'
    );

    HookInboundDispatcher.dispatch(new Set<Id>{ rec.Id });

    Hook_Inbound_Event__c after = reload(rec.Id);
    Assert.areEqual('Processed', after.Status__c);
    Assert.areEqual(1, after.Attempts__c);
    Assert.isNotNull(after.Processed_At__c);
    HookInboundEvent seen = HookTestSupport.seen[0];
    Assert.areEqual(rec.Id, seen.recordId);
    Assert.areEqual('e', seen.endpoint);
    Assert.areEqual('id-1', seen.eventId);
    Assert.areEqual('e:id-1', seen.dedupKey);
    Assert.areEqual(1, seen.attempt);
    Assert.areEqual('{"flow":"X"}', seen.config);
    Assert.areEqual('t-1', seen.header('X-Trace'));
    Assert.areEqual('A-1', seen.valueAt('data.items.0.sku'));
    Assert.isNull(seen.valueAt('data.items.5.sku'));
    Assert.isNull(seen.valueAt('data.nope.x'));
    Assert.isTrue(seen.json() instanceof Map<String, Object>);
  }

  @IsTest
  static void aThrowingHandlerRollsBackItsDmlAndRetries() {
    HookTestSupport.settings();
    HookTestSupport.endpoint('bad', 'NONE')
      .Handler_Class__c = 'HookTestSupport.ThrowingHandler';
    HookTestSupport.endpoint('good', 'NONE');
    Hook_Inbound_Event__c bad = event('bad', 'b-1', '{}');
    Hook_Inbound_Event__c good = event('good', 'g-1', '{}');
    HookClock.fixedSeconds = 1800000000L;

    HookInboundDispatcher.dispatch(new Set<Id>{ bad.Id, good.Id });

    Hook_Inbound_Event__c failed = reload(bad.Id);
    Assert.areEqual('Retrying', failed.Status__c);
    Assert.areEqual(1, failed.Attempts__c);
    Assert.areEqual(
      Datetime.newInstance(1800000060000L),
      failed.Next_Attempt_At__c,
      'base delay 60 s'
    );
    Assert.isTrue(failed.Last_Error__c.contains('handler failed'));
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Hook_Secret__c WHERE Name LIKE 'rolled_back_%'],
      'AC-IN-8'
    );
    Assert.areEqual(
      'Processed',
      reload(good.Id).Status__c,
      'the other event continues'
    );
  }

  @IsTest
  static void theLastAttemptFailsTheRow() {
    HookTestSupport.settings().Max_Attempts__c = 2;
    HookTestSupport.endpoint('bad', 'NONE')
      .Handler_Class__c = 'HookTestSupport.ThrowingHandler';
    Hook_Inbound_Event__c rec = event('bad', 'b-1', '{}');
    rec.Status__c = 'Retrying';
    rec.Attempts__c = 1;
    rec.Next_Attempt_At__c = Datetime.now().addMinutes(-1);
    update rec;

    HookInboundDispatcher.dispatch(new Set<Id>{ rec.Id });

    Hook_Inbound_Event__c after = reload(rec.Id);
    Assert.areEqual('Failed', after.Status__c);
    Assert.areEqual(2, after.Attempts__c);
    Assert.isNull(after.Next_Attempt_At__c);
  }

  @IsTest
  static void theEndpointMaxAttemptsWins() {
    HookTestSupport.settings().Max_Attempts__c = 5;
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('bad', 'NONE');
    ep.Handler_Class__c = 'HookTestSupport.ThrowingHandler';
    ep.Max_Attempts__c = 1;
    Hook_Inbound_Event__c rec = event('bad', 'b-1', '{}');
    HookInboundDispatcher.dispatch(new Set<Id>{ rec.Id });
    Assert.areEqual('Failed', reload(rec.Id).Status__c);
  }

  @IsTest
  static void aMissingHandlerOrEndpointFailsAtOnce() {
    HookTestSupport.settings();
    HookTestSupport.endpoint('nohandler', 'NONE')
      .Handler_Class__c = 'NoSuchClass';
    HookTestSupport.endpoint('wrongtype', 'NONE')
      .Handler_Class__c = 'HookInboundDispatcherTest';
    Hook_Inbound_Event__c a = event('nohandler', 'a', '{}');
    Hook_Inbound_Event__c b = event('wrongtype', 'b', '{}');
    Hook_Inbound_Event__c c = event('gone', 'c', '{}');

    HookInboundDispatcher.dispatch(new Set<Id>{ a.Id, b.Id, c.Id });

    for (Id id : new List<Id>{ a.Id, b.Id, c.Id }) {
      Hook_Inbound_Event__c after = reload(id);
      Assert.areEqual('Failed', after.Status__c, after.Last_Error__c);
      Assert.isNotNull(after.Last_Error__c);
    }
  }

  @IsTest
  static void processedAndNotDueRowsAreSkipped() {
    HookTestSupport.settings();
    HookTestSupport.endpoint('e', 'NONE');
    Hook_Inbound_Event__c done = event('e', 'd', '{}');
    done.Status__c = 'Processed';
    Hook_Inbound_Event__c later = event('e', 'l', '{}');
    later.Status__c = 'Retrying';
    later.Next_Attempt_At__c = Datetime.now().addHours(1);
    update new List<Hook_Inbound_Event__c>{ done, later };

    HookInboundDispatcher.dispatch(new Set<Id>{ done.Id, later.Id });

    Assert.areEqual(0, HookTestSupport.seen.size());
    Assert.areEqual('Retrying', reload(later.Id).Status__c);
  }

  @IsTest
  static void theTriggerProcessesAChunkAndResumesTheRest() {
    HookTestSupport.settings();
    HookTestSupport.endpoint('e', 'NONE');
    HookInboundDispatcher.chunkSize = 2;
    List<Hook_Inbound__e> events = new List<Hook_Inbound__e>();
    for (Integer i = 0; i < 3; i++) {
      events.add(
        new Hook_Inbound__e(Inbound_Event_Id__c = event('e', 'c-' + i, '{}').Id)
      );
    }
    Test.startTest();
    EventBus.publish(events);
    Test.getEventBus().deliver();
    Assert.areEqual(
      2,
      [SELECT COUNT() FROM Hook_Inbound_Event__c WHERE Status__c = 'Processed']
    );
    Test.getEventBus().deliver();
    Test.stopTest();
    Assert.areEqual(
      3,
      [SELECT COUNT() FROM Hook_Inbound_Event__c WHERE Status__c = 'Processed']
    );
  }

  @IsTest
  static void replayInboundSetsPendingAndPublishes() {
    HookTestSupport.settings();
    HookTestSupport.endpoint('e', 'NONE');
    Hook_Inbound_Event__c rec = event('e', 'r-1', '{}');
    rec.Status__c = 'Failed';
    rec.Attempts__c = 3;
    rec.Last_Error__c = 'old';
    update rec;

    Test.startTest();
    Hook.replayInbound(new Set<Id>{ rec.Id });
    Test.stopTest();

    Hook_Inbound_Event__c after = reload(rec.Id);
    Assert.areEqual('Processed', after.Status__c);
    Assert.areEqual(1, after.Attempts__c);
    Assert.areEqual(1, HookTestSupport.seen.size());
  }
}
