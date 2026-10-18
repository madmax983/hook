/**
 * @description The safety net (AC-SW-1 to AC-SW-3). It claims due deliveries,
 * publishes due and stale inbound events, and deletes old done rows. It must
 * see every row, so it runs without sharing.
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
   * @description Runs the sweep now.
   */
  public static void run() {
    Boolean wasInJob = HookAsync.inJob;
    HookAsync.inJob = true;
    try {
      if (HookQueueChannel.hasDue()) {
        HookAsync.enqueue(new HookDispatchJob(null), 0);
      }
      sweepInbound();
      purge();
    } finally {
      HookAsync.inJob = wasInJob;
    }
  }

  private static void sweepInbound() {
    Datetime now = HookClock.now();
    Datetime staleBefore = now.addMinutes(-STALE_MINUTES);
    List<Hook_Inbound_Event__c> rows = [
      SELECT Id, Endpoint__c, Status__c, Attempts__c
      FROM Hook_Inbound_Event__c
      WHERE
        (Status__c = 'Retrying'
        AND Next_Attempt_At__c <= :now)
        OR (Status__c = 'Pending'
        AND Received_At__c < :staleBefore)
      WITH SYSTEM_MODE
      LIMIT :MAX_INBOUND
    ];
    List<Id> publish = new List<Id>();
    List<Hook_Inbound_Event__c> changed = new List<Hook_Inbound_Event__c>();
    for (Hook_Inbound_Event__c rec : rows) {
      if (rec.Status__c == 'Pending') {
        // A Pending row is stale when its dispatch died. Count it, so a
        // poison event cannot loop forever.
        Integer made = rec.Attempts__c == null ? 0 : rec.Attempts__c.intValue();
        Integer max = HookInboundDispatcher.maxAttempts(
          HookEndpoints.get(rec.Endpoint__c)
        );
        if (made >= max) {
          rec.Status__c = 'Failed';
          rec.Last_Error__c =
            'Hook gave up after ' +
            made +
            ' dispatches with no result.';
          changed.add(rec);
          continue;
        }
        rec.Attempts__c = made + 1;
        changed.add(rec);
      }
      publish.add(rec.Id);
    }
    update as system changed;
    HookInboundDispatcher.publish(publish);
  }

  private static void purge() {
    Datetime cutoff = HookClock.now().addDays(-HookConfig.retentionDays());
    delete as system [
      SELECT Id
      FROM Hook_Delivery__c
      WHERE Status__c = 'Delivered' AND Delivered_At__c < :cutoff
      WITH SYSTEM_MODE
      LIMIT :MAX_ROWS
    ];
    delete as system [
      SELECT Id
      FROM Hook_Inbound_Event__c
      WHERE Status__c = 'Processed' AND Processed_At__c < :cutoff
      WITH SYSTEM_MODE
      LIMIT :MAX_ROWS
    ];
  }

  /**
   * @description Schedules four jobs, at minutes 0, 15, 30 and 45. It skips a job that exists.
   */
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
