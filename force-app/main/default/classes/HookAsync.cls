/**
 * @description Enqueues Hook jobs. It skips the enqueue when no Queueable is
 * left; the sweep then finds the rows. In a test it keeps a job that a job
 * enqueues, because a test cannot chain jobs.
 */
public inherited sharing class HookAsync {
  /** @description True while a Hook job runs. */
  public static Boolean inJob = false;

  /** @description Jobs that a test kept. */
  @TestVisible
  private static List<Queueable> deferred = new List<Queueable>();

  /** @description The delays of the kept jobs, in minutes. */
  @TestVisible
  private static List<Integer> deferredDelays = new List<Integer>();

  /**
   * @description Enqueues a job.
   * @param job The job.
   * @param delayMinutes The delay, 0 to 10 minutes.
   * @return True when the job is enqueued or kept.
   */
  public static Boolean enqueue(Queueable job, Integer delayMinutes) {
    Integer delay = Math.max(
      0,
      Math.min(10, delayMinutes == null ? 0 : delayMinutes)
    );
    if (Test.isRunningTest() && (inJob || System.isQueueable())) {
      deferred.add(job);
      deferredDelays.add(delay);
      return true;
    }
    if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
      return false;
    }
    if (delay > 0) {
      System.enqueueJob(job, delay);
    } else {
      System.enqueueJob(job);
    }
    return true;
  }

  /**
   * @description Tells if one more job can be enqueued.
   * @return True when a Queueable is left.
   */
  public static Boolean canEnqueue() {
    return (Test.isRunningTest() && (inJob || System.isQueueable())) ||
      Limits.getQueueableJobs() < Limits.getLimitQueueableJobs();
  }
}
