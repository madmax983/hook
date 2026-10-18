/**
 * @description Processes stored inbound events after commit (ADR 0001).
 */
trigger HookInboundTrigger on Hook_Inbound__e(after insert) {
  HookInboundDispatcher.onEvents(Trigger.new);
}
