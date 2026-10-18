/**
 * @description The default channel: the built-in queue (ADR 0002). It claims
 * rows with a token and a lease, and enqueues one HookDispatchJob for each
 * transaction. It must see every row, so it runs without sharing.
 */
public without sharing class HookQueueChannel implements HookChannel {
  /** @description The class name, as Channel__c holds it. */
  public static final String NAME = 'HookQueueChannel';

  private static String transactionToken;
  private static Boolean enqueued = false;

  /**
   * @description Claims the rows for a job of this transaction. When no
   * Queueable is left, the rows stay Pending and the sweep claims them.
   * @param deliveryIds The Hook_Delivery__c Ids.
   */
  public void dispatch(List<Id> deliveryIds) {
    if (deliveryIds == null || deliveryIds.isEmpty()) {
      return;
    }
    if (!enqueued && !HookAsync.canEnqueue()) {
      return;
    }
    if (transactionToken == null) {
      transactionToken = newToken();
    }
    Datetime lease = HookClock.now().addMinutes(HookConfig.leaseMinutes());
    List<Hook_Delivery__c> rows = new List<Hook_Delivery__c>();
    for (Id id : deliveryIds) {
      rows.add(
        new Hook_Delivery__c(
          Id = id,
          Status__c = 'In_Flight',
          Claim_Token__c = transactionToken,
          Lease_Until__c = lease
        )
      );
    }
    update as system rows;
    if (!enqueued) {
      enqueued = HookAsync.enqueue(new HookDispatchJob(transactionToken), 0);
    }
  }

  /**
   * @description Claims due rows: Pending, Retrying and due, In_Flight with an
   * expired lease, or In_Flight with the given token. It skips rows of an
   * inactive subscription and rows of other channels.
   * @param token A token whose rows the caller gives up, or null.
   * @param max The most rows to claim.
   * @return The new token, or null when it claimed no row.
   */
  public static String claim(String token, Integer max) {
    Datetime now = HookClock.now();
    String given = token == null ? '' : token;
    List<Hook_Delivery__c> rows = [
      SELECT Id
      FROM Hook_Delivery__c
      WHERE
        Channel__c = :NAME
        AND Subscription__r.Active__c = TRUE
        AND (Status__c = 'Pending'
        OR (Status__c = 'Retrying'
        AND Next_Attempt_At__c <= :now)
        OR (Status__c = 'In_Flight'
        AND (Lease_Until__c < :now
        OR Claim_Token__c = :given)))
      WITH SYSTEM_MODE
      LIMIT :max
      FOR UPDATE
    ];
    if (rows.isEmpty()) {
      return null;
    }
    String fresh = newToken();
    Datetime lease = now.addMinutes(HookConfig.leaseMinutes());
    for (Hook_Delivery__c d : rows) {
      d.Status__c = 'In_Flight';
      d.Claim_Token__c = fresh;
      d.Lease_Until__c = lease;
    }
    update as system rows;
    return fresh;
  }

  /**
   * @description Tells if a row is due for a claim.
   * @return True when at least one row is due.
   */
  public static Boolean hasDue() {
    Datetime now = HookClock.now();
    return [
        SELECT COUNT()
        FROM Hook_Delivery__c
        WHERE
          Channel__c = :NAME
          AND Subscription__r.Active__c = TRUE
          AND (Status__c = 'Pending'
          OR (Status__c = 'Retrying'
          AND Next_Attempt_At__c <= :now)
          OR (Status__c = 'In_Flight'
          AND Lease_Until__c < :now))
        WITH SYSTEM_MODE
        LIMIT 1
      ] > 0;
  }

  private static String newToken() {
    return EncodingUtil.convertToHex(Crypto.generateAesKey(128));
  }
}
