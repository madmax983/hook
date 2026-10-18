/**
 * @description Starts an autolaunched Flow for each inbound event.
 * Handler_Config__c: {"flow": "Flow_Api_Name"}. The Flow gets the input
 * variables endpoint, eventId, eventType, body and recordId.
 */
public inherited sharing class HookFlowHandler implements HookInboundHandler {
  /** @description Starts the Flow. Tests replace it. */
  @TestVisible
  private static Launcher launcher = new FlowLauncher();

  /** @description Starts a Flow. Tests replace it. */
  public interface Launcher {
    /**
     * @description Starts the Flow.
     * @param flowName The Flow API name, with a namespace when necessary.
     * @param inputs The input variables.
     */
    void start(String flowName, Map<String, Object> inputs);
  }

  /** @description The production launcher. */
  public class FlowLauncher implements Launcher {
    /**
     * @description Starts the Flow with Flow.Interview.
     * @param flowName The Flow API name.
     * @param inputs The input variables.
     */
    public void start(String flowName, Map<String, Object> inputs) {
      Flow.Interview.createInterview(flowName, inputs).start();
    }
  }

  /**
   * @description Starts the Flow in the handler config.
   * @param event The event.
   */
  public void handle(HookInboundEvent event) {
    Object flowName = HookJson.valueAt(HookJson.parse(event.config), 'flow');
    if (!(flowName instanceof String) || String.isBlank((String) flowName)) {
      throw new HookException(
        'Set "flow" in Handler_Config__c to the Flow API name.'
      );
    }
    launcher.start(
      (String) flowName,
      new Map<String, Object>{
        'endpoint' => event.endpoint,
        'eventId' => event.eventId,
        'eventType' => event.eventType,
        'body' => event.body,
        'recordId' => event.recordId
      }
    );
  }
}
