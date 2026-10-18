/**
 * @description Runs the handler of each stored inbound event (ADR 0001). The
 * trigger on Hook_Inbound__e calls it as the Automated Process user. The sweep
 * and a replay publish the event again. It must see every row, so it runs
 * without sharing.
 */
public without sharing class HookInboundDispatcher {
  /** @description Events for one trigger run. Each event uses two DML statements for its savepoint. */
  @TestVisible
  private static Integer chunkSize = 20;

  /**
   * @description Publishes one Hook_Inbound__e for each row, after commit.
   * @param ids The Hook_Inbound_Event__c Ids.
   */
  public static void publish(List<Id> ids) {
    List<Hook_Inbound__e> events = new List<Hook_Inbound__e>();
    for (Id id : ids) {
      events.add(new Hook_Inbound__e(Inbound_Event_Id__c = id));
    }
    if (!events.isEmpty()) {
      EventBus.publish(events);
    }
  }

  /**
   * @description Handles a trigger batch. It processes one chunk and sets a
   * resume checkpoint, so the platform sends the rest in a new run.
   * @param events The trigger events.
   */
  public static void onEvents(List<Hook_Inbound__e> events) {
    Set<Id> ids = new Set<Id>();
    Integer count = Math.min(events.size(), chunkSize);
    for (Integer i = 0; i < count; i++) {
      Id id = toId(events[i].Inbound_Event_Id__c);
      if (id != null) {
        ids.add(id);
      }
    }
    if (events.size() > count) {
      EventBus.TriggerContext.currentContext()
        .setResumeCheckpoint(events[count - 1].ReplayId);
    }
    dispatch(ids);
  }

  private static Id toId(String value) {
    try {
      return Id.valueOf(value);
    } catch (Exception e) {
      return null;
    }
  }

  /**
   * @description Runs the handler for each due row. It skips a row that is
   * done, or a Retrying row that is not due.
   * @param ids The Hook_Inbound_Event__c Ids.
   */
  public static void dispatch(Set<Id> ids) {
    Datetime now = HookClock.now();
    List<Hook_Inbound_Event__c> rows = [
      SELECT
        Id,
        Endpoint__c,
        Event_Id__c,
        Event_Type__c,
        Dedup_Key__c,
        Body__c,
        Headers__c,
        Status__c,
        Attempts__c,
        Next_Attempt_At__c
      FROM Hook_Inbound_Event__c
      WHERE Id IN :ids AND Status__c IN ('Pending', 'Retrying')
      WITH SYSTEM_MODE
    ];
    List<Hook_Inbound_Event__c> changed = new List<Hook_Inbound_Event__c>();
    for (Hook_Inbound_Event__c rec : rows) {
      if (
        rec.Status__c == 'Retrying' &&
        rec.Next_Attempt_At__c != null &&
        rec.Next_Attempt_At__c > now
      ) {
        continue;
      }
      run(rec);
      changed.add(rec);
    }
    update as system changed;
  }

  private static void run(Hook_Inbound_Event__c rec) {
    Integer attempt =
      (rec.Attempts__c == null ? 0 : rec.Attempts__c.intValue()) + 1;
    rec.Attempts__c = attempt;
    Hook_Endpoint__mdt ep = HookEndpoints.get(rec.Endpoint__c);
    HookInboundHandler handler;
    try {
      handler = resolve(ep, rec.Endpoint__c);
    } catch (HookException e) {
      fail(rec, e.getMessage());
      return;
    }
    Savepoint sp = Database.setSavepoint();
    try {
      handler.handle(new HookInboundEvent(rec, ep, attempt));
      rec.Status__c = 'Processed';
      rec.Processed_At__c = HookClock.now();
      rec.Next_Attempt_At__c = null;
      rec.Last_Error__c = null;
    } catch (Exception e) {
      Database.rollback(sp);
      retryOrFail(rec, ep, e.getTypeName() + ': ' + e.getMessage());
    }
  }

  private static HookInboundHandler resolve(
    Hook_Endpoint__mdt ep,
    String name
  ) {
    if (ep == null) {
      throw new HookException('The endpoint "' + name + '" is not found.');
    }
    Object handler = HookTypes.make(ep.Handler_Class__c, 'HookInboundHandler');
    if (!(handler instanceof HookInboundHandler)) {
      throw HookTypes.wrongType(ep.Handler_Class__c, 'HookInboundHandler');
    }
    return (HookInboundHandler) handler;
  }

  /**
   * @description Gives the maximum attempts of an endpoint.
   * @param ep The endpoint, or null.
   * @return The endpoint value, else the org default.
   */
  public static Integer maxAttempts(Hook_Endpoint__mdt ep) {
    return ep != null &&
      ep.Max_Attempts__c != null
      ? Math.max(1, ep.Max_Attempts__c.intValue())
      : HookConfig.maxAttempts();
  }

  private static void retryOrFail(
    Hook_Inbound_Event__c rec,
    Hook_Endpoint__mdt ep,
    String error
  ) {
    Integer attempts = rec.Attempts__c.intValue();
    if (attempts >= maxAttempts(ep)) {
      fail(rec, error);
      return;
    }
    rec.Status__c = 'Retrying';
    rec.Last_Error__c = error.left(32768);
    rec.Next_Attempt_At__c = HookClock.now()
      .addSeconds(
        HookBackoff.delaySeconds(
          attempts,
          HookConfig.baseDelaySeconds(),
          HookConfig.maxDelaySeconds()
        )
      );
  }

  private static void fail(Hook_Inbound_Event__c rec, String error) {
    rec.Status__c = 'Failed';
    rec.Last_Error__c = error == null ? null : error.left(32768);
    rec.Next_Attempt_At__c = null;
  }
}
