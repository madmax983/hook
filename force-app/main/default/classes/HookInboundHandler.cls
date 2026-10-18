/**
 * @description Processes one stored inbound event. Hook calls it after commit,
 * as the Automated Process user. Make it idempotent: Hook can call it again.
 * Do not call out: a platform event trigger cannot. Enqueue a job instead.
 */
global interface HookInboundHandler {
  /**
   * @description Processes the event. Throw to retry. Hook rolls back the DML
   * of a failed call.
   * @param event The event.
   */
  void handle(HookInboundEvent event);
}
