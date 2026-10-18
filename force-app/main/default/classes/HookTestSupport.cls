/**
 * @description Test data and fakes for the Hook tests.
 */
@IsTest
public class HookTestSupport {
  /** @description Name of the default test secret. */
  public static final String SECRET_NAME = 'test_secret';

  /** @description The events that RecordingHandler got. */
  public static List<HookInboundEvent> seen = new List<HookInboundEvent>();

  /** @description The requests that MockHttp got. */
  public static List<HttpRequest> requests = new List<HttpRequest>();

  /** @description The Ids that RecordingChannel got. */
  public static List<Id> dispatched = new List<Id>();

  /**
   * @description Reads the static resource HookTestVectors.
   * @return The vectors as an untyped map.
   */
  public static Map<String, Object> vectors() {
    StaticResource res = [
      SELECT Body
      FROM StaticResource
      WHERE Name = 'HookTestVectors'
      LIMIT 1
    ];
    return (Map<String, Object>) JSON.deserializeUntyped(res.Body.toString());
  }

  /**
   * @description Reads one group of vectors.
   * @param name The group name.
   * @return The group as a map.
   */
  public static Map<String, Object> vector(String name) {
    return (Map<String, Object>) vectors().get(name);
  }

  /**
   * @description Registers an active test endpoint with the recording handler.
   * @param name The endpoint name.
   * @param scheme The verification scheme.
   * @return The endpoint record. Change it to change the configuration.
   */
  public static Hook_Endpoint__mdt endpoint(String name, String scheme) {
    Hook_Endpoint__mdt ep = new Hook_Endpoint__mdt(
      DeveloperName = name,
      Active__c = true,
      Scheme__c = scheme,
      Secret_Names__c = SECRET_NAME,
      Handler_Class__c = 'HookTestSupport.RecordingHandler'
    );
    HookEndpoints.overrides.put(name, ep);
    return ep;
  }

  /**
   * @description Sets the org settings for a test.
   * @return The settings record. Change it to change the settings.
   */
  public static Hook_Setting__mdt settings() {
    Hook_Setting__mdt s = new Hook_Setting__mdt(
      DeveloperName = 'Default',
      Batch_Size__c = 10,
      Timeout_Ms__c = 10000,
      Max_Attempts__c = 3,
      Base_Delay_Seconds__c = 60,
      Max_Delay_Seconds__c = 3600,
      Disable_After_Failures__c = 0,
      Lease_Minutes__c = 10,
      Retention_Days__c = 30
    );
    HookConfig.current = s;
    HookBackoff.jitterEnabled = false;
    return s;
  }

  /**
   * @description Stores a secret.
   * @param name The secret name.
   * @param value The secret value.
   */
  public static void secret(String name, String value) {
    insert new Hook_Secret__c(Name = name, Value__c = value);
  }

  /**
   * @description Makes an inbound request.
   * @param endpoint The endpoint name.
   * @param body The body.
   * @param headers The headers.
   * @return The request.
   */
  public static HookRequest request(
    String endpoint,
    String body,
    Map<String, String> headers
  ) {
    return new HookRequest(
      'POST',
      endpoint,
      body == null ? null : Blob.valueOf(body),
      headers,
      new Map<String, String>(),
      '203.0.113.7'
    );
  }

  /**
   * @description Inserts an active subscription with a secret.
   * @param name The subscription name.
   * @param eventTypes The event type filter.
   * @return The subscription.
   */
  public static Hook_Subscription__c subscription(
    String name,
    String eventTypes
  ) {
    String secretName = 'sub_' + name;
    secret(
      secretName,
      'whsec_' +
      EncodingUtil.base64Encode(Blob.valueOf(name + '-key-0123456789'))
    );
    Hook_Subscription__c sub = new Hook_Subscription__c(
      Name = name,
      Endpoint__c = 'https://example.com/hooks/' + name,
      Event_Types__c = eventTypes,
      Secret_Name__c = secretName,
      Active__c = true
    );
    insert sub;
    return sub;
  }

  /**
   * @description Inserts a delivery row for a subscription.
   * @param sub The subscription.
   * @param status The status.
   * @return The delivery.
   */
  public static Hook_Delivery__c delivery(
    Hook_Subscription__c sub,
    String status
  ) {
    String eventId =
      'msg_' + String.valueOf(Crypto.getRandomLong()).replace('-', '');
    Hook_Delivery__c d = new Hook_Delivery__c(
      Subscription__c = sub.Id,
      Event_Id__c = eventId,
      Event_Type__c = 'order.paid',
      Dedup_Key__c = sub.Id + ':' + eventId,
      Payload__c = '{"id":"' +
        eventId +
        '","type":"order.paid","timestamp":"2026-10-18T00:00:00Z","data":{"n":1}}',
      Status__c = status,
      Attempts__c = 0,
      Generation__c = 0,
      Channel__c = HookQueueChannel.NAME
    );
    insert d;
    return d;
  }

  /**
   * @description Reads one delivery with every field the tests check.
   * @param id The delivery Id.
   * @return The delivery.
   */
  public static Hook_Delivery__c reload(Id id) {
    return [
      SELECT
        Id,
        Status__c,
        Attempts__c,
        Next_Attempt_At__c,
        Last_Status_Code__c,
        Last_Error__c,
        Last_Response__c,
        Delivered_At__c,
        Claim_Token__c,
        Lease_Until__c,
        Generation__c,
        Payload__c,
        Event_Id__c,
        Channel__c
      FROM Hook_Delivery__c
      WHERE Id = :id
    ];
  }

  /**
   * @description Records each inbound event it gets.
   */
  public class RecordingHandler implements HookInboundHandler {
    /**
     * @description Keeps the event.
     * @param event The event.
     */
    public void handle(HookInboundEvent event) {
      seen.add(event);
    }
  }

  /**
   * @description Does DML, then throws, so the test can check the rollback.
   */
  public class ThrowingHandler implements HookInboundHandler {
    /**
     * @description Inserts a secret, then throws.
     * @param event The event.
     */
    public void handle(HookInboundEvent event) {
      insert new Hook_Secret__c(Name = 'rolled_back_' + event.eventId);
      throw new HookException('handler failed');
    }
  }

  /**
   * @description Gives fixed responses and keeps each request.
   */
  public class MockHttp implements HttpCalloutMock {
    private final List<HttpResponse> responses = new List<HttpResponse>();

    /**
     * @description Adds a response. The mock gives them in order and then repeats the last.
     * @param status The status code.
     * @param body The body.
     * @param headers The headers, or null.
     * @return This mock.
     */
    public MockHttp add(
      Integer status,
      String body,
      Map<String, String> headers
    ) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(status);
      res.setBody(body == null ? '' : body);
      if (headers != null) {
        for (String key : headers.keySet()) {
          res.setHeader(key, headers.get(key));
        }
      }
      responses.add(res);
      return this;
    }

    /**
     * @description Gives the next response.
     * @param req The request.
     * @return The response.
     */
    public HttpResponse respond(HttpRequest req) {
      requests.add(req);
      if (responses.size() > 1) {
        return responses.remove(0);
      }
      return responses[0];
    }
  }

  /**
   * @description Throws a CalloutException, as a timeout does.
   */
  public class TimeoutHttp implements HttpCalloutMock {
    /**
     * @description Throws.
     * @param req The request.
     * @return Never.
     */
    public HttpResponse respond(HttpRequest req) {
      requests.add(req);
      throw new CalloutException('Read timed out');
    }
  }

  /**
   * @description A test channel that keeps the Ids it gets.
   */
  public class RecordingChannel implements HookChannel {
    /**
     * @description Keeps the Ids.
     * @param deliveryIds The delivery Ids.
     */
    public void dispatch(List<Id> deliveryIds) {
      dispatched.addAll(deliveryIds);
    }
  }

  /**
   * @description A transport with fixed status codes and no real callout.
   * Use it where a test must call out after DML, as the Revenant harness does.
   */
  public class FakeTransport implements HookTransport {
    private final List<Integer> codes;

    /**
     * @description Makes the fake.
     * @param codes The status codes, in order. The last one repeats.
     */
    public FakeTransport(List<Integer> codes) {
      this.codes = codes;
    }

    /**
     * @description Gives the next status code.
     * @param req The request.
     * @return The response.
     */
    public HttpResponse send(HttpRequest req) {
      requests.add(req);
      HttpResponse res = new HttpResponse();
      res.setStatusCode(codes.size() > 1 ? codes.remove(0) : codes[0]);
      res.setBody('');
      return res;
    }
  }
}
