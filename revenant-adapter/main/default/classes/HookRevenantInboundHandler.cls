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
    if (mode == 'start') {
      start(event, config);
    } else if (mode == 'signal') {
      signal(event, config);
    } else {
      throw new HookException(
        'Set "mode" in Handler_Config__c to start or signal.'
      );
    }
  }

  private static void start(
    HookInboundEvent event,
    Map<String, Object> config
  ) {
    String key = keyFrom(event, text(config, 'keyPath'));
    WorkflowEngine.startOrGet(
      new WorkflowEngine.StartRequest(
        required(config, 'workflow'),
        String.isBlank(key) ? event.dedupKey : key,
        new Map<String, Object>{
          'endpoint' => event.endpoint,
          'eventId' => event.eventId,
          'eventType' => event.eventType,
          'payload' => event.json()
        }
      )
    );
  }

  private static void signal(
    HookInboundEvent event,
    Map<String, Object> config
  ) {
    String signalName = required(config, 'signal');
    String keyPath = text(config, 'keyPath');
    String key = keyFrom(event, keyPath);
    if (String.isBlank(key)) {
      throw new HookException(
        'No target key at keyPath "' +
          keyPath +
          '". The path is missing or empty.'
      );
    }
    WorkflowEngine.signal(
      new WorkflowEngine.SignalRequest(key, signalName, event.body)
        .withIdempotencyKey(event.dedupKey)
    );
  }

  private static String keyFrom(HookInboundEvent event, String keyPath) {
    Object value = String.isBlank(keyPath) ? null : event.valueAt(keyPath);
    return value == null ? null : String.valueOf(value);
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
