/**
 * @description Publishes the inbound rows whose retry is due. The dispatcher
 * enqueues it with a delay for a short retry.
 */
public without sharing class HookInboundRetryJob implements Queueable {
  /**
   * @description Publishes the due rows.
   * @param ctx The context.
   */
  public void execute(QueueableContext ctx) {
    HookSweep.republishInbound();
  }
}
