/**
 * @description Releases the rows of a HookDispatchJob that stopped with an
 * uncaught error, for example a limit error. Each row gets one more attempt
 * and a retry after the base delay, or Failed when no attempt is left. Then a
 * poison row cannot loop forever. A claim job runs after 1 minute. It must see every row, so it runs without
 * sharing.
 */
public without sharing class HookDispatchFinalizer implements Finalizer {
  private final String token;

  /**
   * @description Makes the finalizer.
   * @param token The claim token of the job.
   */
  public HookDispatchFinalizer(String token) {
    this.token = token;
  }

  /**
   * @description Releases the rows when the job failed.
   * @param ctx The context.
   */
  public void execute(FinalizerContext ctx) {
    if (ctx.getResult() != ParentJobResult.UNHANDLED_EXCEPTION) {
      return;
    }
    Exception e = ctx.getException();
    release(
      e == null ? 'unknown error' : e.getTypeName() + ': ' + e.getMessage()
    );
  }

  private void release(String error) {
    List<Hook_Delivery__c> rows = [
      SELECT Id, Attempts__c, Subscription__r.Max_Attempts__c
      FROM Hook_Delivery__c
      WHERE Claim_Token__c = :token AND Status__c = 'In_Flight'
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (rows.isEmpty()) {
      return;
    }
    Datetime next = HookClock.now().addSeconds(HookConfig.baseDelaySeconds());
    for (Hook_Delivery__c d : rows) {
      Integer made = (d.Attempts__c == null ? 0 : d.Attempts__c.intValue()) + 1;
      Decimal subMax = d.Subscription__r.Max_Attempts__c;
      Integer max = subMax == null
        ? HookConfig.maxAttempts()
        : Math.max(1, subMax.intValue());
      d.Attempts__c = made;
      d.Claim_Token__c = null;
      d.Lease_Until__c = null;
      d.Last_Error__c = ('The dispatch job failed: ' + error).left(32768);
      d.Status__c = made >= max ? 'Failed' : 'Retrying';
      d.Next_Attempt_At__c = made >= max ? null : next;
    }
    update as system rows;
    HookAsync.enqueue(new HookDispatchJob(null), 1);
  }
}
