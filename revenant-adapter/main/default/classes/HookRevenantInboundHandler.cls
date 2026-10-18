/**
 * @description An inbound handler that starts or signals a Revenant workflow.
 * Set Handler_Class__c to HookRevenantInboundHandler. Handler_Config__c:
 * - {"mode": "start", "workflow": "Name", "keyPath": "optional.path"}
 * - {"mode": "signal", "signal": "Name", "keyPath": "path.to.target.key"}
 * The workflow input is {endpoint, eventId, eventType, payload}, where payload
 * is the parsed body. The signal payload is the body. The default start key
 * and the signal idempotency key are the event dedup key. A key longer than
 * 200 characters becomes sha256: and its hash. A start key that an instance
 * of another workflow has is an error. A signal to a key with no running
 * instance is an error, so Hook retries it.
 */
public inherited sharing class HookRevenantInboundHandler implements HookInboundHandler {
  private static final Integer MAX_KEY = 200;

  /**
   * @description Starts or signals the workflow.
   * @param event The event.
   */
  public void handle(HookInboundEvent event) {
    Map<String, Object> config = parseConfig(event.config);
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

  private static Map<String, Object> parseConfig(String text) {
    try {
      Object parsed = JSON.deserializeUntyped(text);
      if (parsed instanceof Map<String, Object>) {
        return (Map<String, Object>) parsed;
      }
    } catch (Exception e) {
      throw new HookException('Handler_Config__c is not a JSON object.');
    }
    throw new HookException('Handler_Config__c is not a JSON object.');
  }

  private static void start(
    HookInboundEvent event,
    Map<String, Object> config
  ) {
    String workflow = required(config, 'workflow');
    String key = keyFrom(event, text(config, 'keyPath'));
    WorkflowEngine.StartResult result = WorkflowEngine.startOrGet(
      new WorkflowEngine.StartRequest(
        workflow,
        safeKey(String.isBlank(key) ? event.dedupKey : key),
        new Map<String, Object>{
          'endpoint' => event.endpoint,
          'eventId' => event.eventId,
          'eventType' => event.eventType,
          'payload' => event.json()
        }
      )
    );
    if (!result.isNew) {
      WorkflowEngine.WorkflowStatus existing = WorkflowStatusRead.getStatus(
        result.instanceId
      );
      if (existing != null && !existing.definitionName.endsWith(workflow)) {
        throw new HookException(
          'The key "' +
            key +
            '" belongs to an instance of ' +
            existing.definitionName +
            ', not ' +
            workflow +
            '.'
        );
      }
    }
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
    key = safeKey(key);
    WorkflowEngine.WorkflowStatus target = WorkflowStatusRead.getStatus(key);
    if (target == null || target.isTerminal) {
      throw new HookException('No running workflow has the key "' + key + '".');
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

  // Revenant accepts a key of at most 200 characters.
  private static String safeKey(String key) {
    if (key.length() <= MAX_KEY) {
      return key;
    }
    return 'sha256:' +
      EncodingUtil.convertToHex(
        Crypto.generateDigest('SHA-256', Blob.valueOf(key))
      );
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
