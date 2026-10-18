/**
 * @description The safety net (AC-SW-1 to AC-SW-3). It claims due deliveries,
 * publishes due and stale inbound events, and deletes old done rows. Failed
 * rows stay as a dead letter list. It must see every row, so it runs without
 * sharing.
 */
public without sharing class HookSweep implements Schedulable {
  /** @description The name prefix of the scheduled jobs. */
  public static final String JOB_PREFIX = 'Hook Sweep';
  /** @description A Pending inbound row older than this is stale. */
  private static final Integer STALE_MINUTES = 5;
  /** @description Most rows of each kind in one sweep. */
  private static final Integer MAX_ROWS = 2000;
  private static final Integer MAX_INBOUND = 200;

  /**
   * @description Runs the sweep.
   * @param ctx The context.
   */
  public void execute(SchedulableContext ctx) {
    run();
  }

  /**
   * @description Runs the sweep now. Each part runs on its own: an error in
   * one part does not stop the other parts.
   */
  public static void run() {
    Boolean wasInJob = HookAsync.inJob;
    HookAsync.inJob = true;
    try {
      try {
        if (HookQueueChannel.hasDue()) {
          HookAsync.enqueue(new HookDispatchJob(null), 0);
        }
      } catch (Exception e) {
        log('claim', e);
      }
      try {
        republishInbound();
      } catch (Exception e) {
        log('inbound', e);
      }
      try {
        purge();
      } catch (Exception e) {
        log('purge', e);
      }
    } finally {
      HookAsync.inJob = wasInJob;
    }
  }

  @SuppressWarnings('PMD.AvoidDebugStatements')
  private static void log(String part, Exception e) {
    System.debug(
      LoggingLevel.ERROR,
      'Hook sweep ' + part + ': ' + e.getMessage()
    );
  }

  /**
   * @description Publishes the inbound rows that wait: a due Retrying row, a
   * Pending row whose publish failed, and a row whose last dispatch is more
   * than 5 minutes old with no result. A dispatch with no result counts as an
   * attempt, so a poison event cannot loop forever.
   */
  public static void republishInbound() {
    Datetime now = HookClock.now();
    Datetime staleBefore = now.addMinutes(-STALE_MINUTES);
    List<Hook_Inbound_Event__c> rows = [
      SELECT
        Id,
        Endpoint__c,
        Status__c,
        Attempts__c,
        Next_Attempt_At__c,
        Dispatched_At__c
      FROM Hook_Inbound_Event__c
      WHERE
        (Status__c = 'Retrying'
        AND Next_Attempt_At__c <= :now)
        OR (Status__c = 'Pending'
        AND (Dispatched_At__c = NULL
        OR Dispatched_At__c < :staleBefore))
      WITH SYSTEM_MODE
      ORDER BY Received_At__c
      LIMIT :MAX_INBOUND
    ];
    List<Hook_Inbound_Event__c> publish = new List<Hook_Inbound_Event__c>();
    List<Hook_Inbound_Event__c> failed = new List<Hook_Inbound_Event__c>();
    for (Hook_Inbound_Event__c rec : rows) {
      Boolean lost =
        rec.Dispatched_At__c != null &&
        (rec.Status__c == 'Pending' ||
        rec.Dispatched_At__c >= rec.Next_Attempt_At__c);
      if (lost && rec.Dispatched_At__c >= staleBefore) {
        continue;
      }
      if (lost) {
        Integer made =
          (rec.Attempts__c == null ? 0 : rec.Attempts__c.intValue()) + 1;
        rec.Attempts__c = made;
        if (
          made >=
          HookInboundDispatcher.maxAttempts(HookEndpoints.get(rec.Endpoint__c))
        ) {
          rec.Status__c = 'Failed';
          rec.Next_Attempt_At__c = null;
          rec.Last_Error__c =
            'Hook gave up after ' +
            made +
            ' dispatches with no result.';
          failed.add(rec);
          continue;
        }
      }
      publish.add(rec);
    }
    HookInboundDispatcher.publish(publish);
    publish.addAll(failed);
    update as system publish;
  }

  private static void purge() {
    Datetime cutoff = HookClock.now().addDays(-HookConfig.retentionDays());
    Database.delete(
      [
        SELECT Id
        FROM Hook_Delivery__c
        WHERE Status__c = 'Delivered' AND Delivered_At__c < :cutoff
        WITH SYSTEM_MODE
        LIMIT :MAX_ROWS
      ],
      false,
      AccessLevel.SYSTEM_MODE
    );
    Database.delete(
      [
        SELECT Id
        FROM Hook_Inbound_Event__c
        WHERE Status__c = 'Processed' AND Processed_At__c < :cutoff
        WITH SYSTEM_MODE
        LIMIT :MAX_ROWS
      ],
      false,
      AccessLevel.SYSTEM_MODE
    );
  }

  /**
   * @description Schedules four jobs, at minutes 0, 15, 30 and 45. It skips a job that exists.
   */
  @SuppressWarnings('PMD.OperationWithLimitsInLoop')
  public static void schedule() {
    Set<String> existing = new Set<String>();
    for (CronTrigger ct : jobs()) {
      existing.add(ct.CronJobDetail.Name);
    }
    for (Integer minute : new List<Integer>{ 0, 15, 30, 45 }) {
      String name = JOB_PREFIX + ' :' + String.valueOf(minute).leftPad(2, '0');
      if (!existing.contains(name)) {
        System.schedule(name, '0 ' + minute + ' * * * ?', new HookSweep());
      }
    }
  }

  /**
   * @description Removes the scheduled sweep jobs.
   */
  public static void unschedule() {
    for (CronTrigger ct : jobs()) {
      System.abortJob(ct.Id);
    }
  }

  private static List<CronTrigger> jobs() {
    String pattern = JOB_PREFIX + '%';
    return [
      SELECT Id, CronJobDetail.Name
      FROM CronTrigger
      WHERE CronJobDetail.Name LIKE :pattern
      WITH SYSTEM_MODE
    ];
  }
}
