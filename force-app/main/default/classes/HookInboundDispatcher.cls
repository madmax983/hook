/**
 * @description Runs the handler of each stored inbound event (ADR 0001). The
 * trigger on Hook_Inbound__e calls it as the Automated Process user. The sweep
 * and a replay publish the event again. It must see every row, so it runs
 * without sharing.
 */
public without sharing class HookInboundDispatcher {
  /** @description Most events for one trigger run. */
  @TestVisible
  private static Integer chunkSize = 20;
  /** @description Longest retry delay that a delayed job covers. The sweep covers longer ones. */
  private static final Integer DELAYED_JOB_MAX_SECONDS = 600;

  /**
   * @description Publishes one Hook_Inbound__e for each row, after commit.
   * It sets Dispatched_At__c on each row in memory. A row whose publish fails
   * gets a null Dispatched_At__c, so the sweep publishes it again with no
   * attempt counted. The caller saves the rows.
   * @param rows The rows. Each has an Id.
   */
  public static void publish(List<Hook_Inbound_Event__c> rows) {
    if (rows.isEmpty()) {
      return;
    }
    List<Hook_Inbound__e> events = new List<Hook_Inbound__e>();
    Datetime now = HookClock.now();
    for (Hook_Inbound_Event__c rec : rows) {
      events.add(new Hook_Inbound__e(Inbound_Event_Id__c = rec.Id));
      rec.Dispatched_At__c = now;
    }
    List<Database.SaveResult> results = EventBus.publish(events);
    for (Integer i = 0; i < results.size(); i++) {
      if (!results[i].isSuccess()) {
        rows[i].Dispatched_At__c = null;
      }
    }
  }

  /**
   * @description Handles a trigger batch. It stops after chunkSize events, or
   * when half of a limit is used. It sets a resume checkpoint, so the
   * platform sends the rest in a new run.
   * @param events The trigger events.
   */
  public static void onEvents(List<Hook_Inbound__e> events) {
    List<Id> ids = new List<Id>();
    for (Hook_Inbound__e e : events) {
      ids.add(toId(e.Inbound_Event_Id__c));
    }
    Integer done = dispatchInOrder(ids, chunkSize);
    if (done < events.size()) {
      EventBus.TriggerContext.currentContext()
        .setResumeCheckpoint(events[done - 1].ReplayId);
    }
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
    dispatchInOrder(new List<Id>(ids), ids.size());
  }

  // Runs the rows in the order of the Ids. Gives the count of Ids used: at
  // least 1, at most max. It stops early when half of a limit is used.
  private static Integer dispatchInOrder(List<Id> ids, Integer max) {
    Map<Id, Hook_Inbound_Event__c> rows = new Map<Id, Hook_Inbound_Event__c>(
      [
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
      ]
    );
    Datetime now = HookClock.now();
    List<Hook_Inbound_Event__c> changed = new List<Hook_Inbound_Event__c>();
    Integer used = 0;
    while (used < Math.min(max, ids.size())) {
      Hook_Inbound_Event__c rec = rows.remove(ids[used]);
      used++;
      if (
        rec == null ||
        (rec.Status__c == 'Retrying' &&
        rec.Next_Attempt_At__c > now)
      ) {
        continue;
      }
      run(rec);
      changed.add(rec);
      if (nearLimits()) {
        break;
      }
    }
    update as system changed;
    armTimer(changed);
    return Math.max(1, used);
  }

  private static Boolean nearLimits() {
    return Limits.getCpuTime() * 2 > Limits.getLimitCpuTime() ||
      Limits.getQueries() * 2 > Limits.getLimitQueries() ||
      Limits.getDmlStatements() * 2 > Limits.getLimitDmlStatements() ||
      Limits.getDmlRows() * 2 > Limits.getLimitDmlRows();
  }

  // When a retry is due in 10 minutes or less, a delayed job publishes it.
  private static void armTimer(List<Hook_Inbound_Event__c> rows) {
    Datetime first;
    for (Hook_Inbound_Event__c rec : rows) {
      if (
        rec.Status__c == 'Retrying' &&
        (first == null ||
        rec.Next_Attempt_At__c < first)
      ) {
        first = rec.Next_Attempt_At__c;
      }
    }
    if (first == null) {
      return;
    }
    Long seconds = (first.getTime() - HookClock.now().getTime()) / 1000;
    if (seconds <= DELAYED_JOB_MAX_SECONDS) {
      HookAsync.enqueue(
        new HookInboundRetryJob(),
        Math.max(1, Math.ceil(seconds / 60.0).intValue())
      );
    }
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
