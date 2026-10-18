/**
 * @description An inbound handler that starts or signals a Revenant workflow.
 * Set Handler_Class__c to HookRevenantInboundHandler. Handler_Config__c:
 * - {"mode": "start", "workflow": "Name", "keyPath": "optional.path"}
 * - {"mode": "signal", "signal": "Name", "keyPath": "path.to.target.key"}
 * The workflow input or the signal payload is the event body. The default
 * start key and the signal idempotency key are the event dedup key.
 */
public inherited sharing class HookRevenantInboundHandler implements HookInboundHandler {
  /**
   * @description Starts or signals the workflow.
   * @param event The event.
   */
  public void handle(HookInboundEvent event) {
    Object parsed = HookJson.parse(event.config);
    Map<String, Object> config = parsed instanceof Map<String, Object>
      ? (Map<String, Object>) parsed
      : new Map<String, Object>();
    String mode = text(config, 'mode');
    String keyPath = text(config, 'keyPath');
    Object keyValue = String.isBlank(keyPath) ? null : event.valueAt(keyPath);
    String key = keyValue == null ? null : String.valueOf(keyValue);
    if (mode == 'start') {
      String workflow = required(config, 'workflow');
      WorkflowEngine.startOrGet(
        new WorkflowEngine.StartRequest(
          workflow,
          String.isBlank(key) ? event.dedupKey : key,
          new Map<String, Object>{
            'endpoint' => event.endpoint,
            'eventId' => event.eventId,
            'eventType' => event.eventType,
            'payload' => event.json()
          }
        )
      );
    } else if (mode == 'signal') {
      String signal = required(config, 'signal');
      if (String.isBlank(key)) {
        throw new HookException(
          'No target key at keyPath "' +
            keyPath +
            '". The path is missing or empty.'
        );
      }
      WorkflowEngine.signal(
        new WorkflowEngine.SignalRequest(key, signal, event.body)
          .withIdempotencyKey(event.dedupKey)
      );
    } else {
      throw new HookException(
        'Set "mode" in Handler_Config__c to start or signal.'
      );
    }
  }

  private static String text(Map<String, Object> config, String name) {
    Object value = config.get(name);
    return value == null ? null : String.valueOf(value);
  }

  private static String required(Map<String, Object> config, String name) {
    String value = text(config, name);
    if (String.isBlank(value)) {
      throw new HookException('Set "' + name + '" in Handler_Config__c.');
    }
    return value;
  }
}
