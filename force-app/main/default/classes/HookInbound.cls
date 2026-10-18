/**
 * @description Receives one inbound request: route, verify, deduplicate, store
 * and publish (ADR 0001). It runs as the Site guest user. It sees only the
 * configuration and the new row, so it runs without sharing.
 */
public without sharing class HookInbound {
  /** @description Largest body. It is the Body__c length. */
  public static final Integer MAX_BODY_CHARS = 131072;
  /** @description Largest Event_Id__c and Dedup_Key__c. */
  private static final Integer MAX_KEY = 255;
  /** @description Headers that Hook does not store (AC-SEC-5). */
  private static final Set<String> SECRET_HEADERS = new Set<String>{
    'authorization',
    'cookie',
    'proxy-authorization'
  };

  /**
   * @description Handles a request. It returns 500 for an unexpected error, so the provider retries.
   * @param request The request.
   * @return The response.
   */
  public static HookResponse receive(HookRequest request) {
    Savepoint sp = Database.setSavepoint();
    try {
      return handle(request);
    } catch (Exception e) {
      Database.rollback(sp);
      System.debug(
        LoggingLevel.ERROR,
        'Hook inbound error: ' + e.getMessage() + '\n' + e.getStackTraceString()
      );
      return error(500, 'internal error');
    }
  }

  private static HookResponse handle(HookRequest request) {
    Hook_Endpoint__mdt ep = HookEndpoints.get(request.endpoint);
    if (ep == null || ep.Active__c != true) {
      return error(404, 'unknown endpoint');
    }
    if (request.bodyBlob.size() > MAX_BODY_CHARS * 4) {
      return error(413, 'body too large');
    }
    if (!request.decodeBody()) {
      return error(400, 'body is not UTF-8');
    }
    if (request.body.length() > MAX_BODY_CHARS) {
      return error(413, 'body too large');
    }
    List<String> secrets = HookSecrets.valuesFor(ep.Secret_Names__c);
    HookVerifier verifier = HookVerifiers.forEndpoint(ep);
    Object handler = String.isBlank(ep.Handler_Class__c)
      ? null
      : HookTypes.make(ep.Handler_Class__c, 'HookInboundHandler');

    if (request.method == 'GET') {
      HookResponse answer = handshake(verifier, handler, request, secrets);
      return answer != null ? answer : error(405, 'method not allowed');
    }
    HookVerification verification = verifier.verify(request, secrets);
    if (verification == null || verification.isValid != true) {
      return error(
        401,
        verification == null ? 'not verified' : verification.reason
      );
    }
    HookResponse answer = handshake(verifier, handler, request, secrets);
    if (answer != null) {
      return answer;
    }
    return store(ep, request, verification);
  }

  private static HookResponse handshake(
    Object verifier,
    Object handler,
    HookRequest request,
    List<String> secrets
  ) {
    for (Object candidate : new List<Object>{ verifier, handler }) {
      if (candidate instanceof HookHandshake) {
        HookResponse answer = ((HookHandshake) candidate)
          .respond(request, secrets);
        if (answer != null) {
          return answer;
        }
      }
    }
    return null;
  }

  private static HookResponse store(
    Hook_Endpoint__mdt ep,
    HookRequest request,
    HookVerification v
  ) {
    String eventId = firstNonBlank(
      new List<String>{
        v.eventId,
        request.header(ep.Event_Id_Header__c),
        HookJson.textAt(request.body, ep.Event_Id_Path__c)
      }
    );
    if (eventId == null) {
      eventId = sha256(request.bodyBlob);
    }
    String eventType = firstNonBlank(
      new List<String>{
        v.eventType,
        request.header(ep.Event_Type_Header__c),
        HookJson.textAt(request.body, ep.Event_Type_Path__c)
      }
    );
    String name = ep.DeveloperName;
    String dedupKey = name + ':' + eventId;
    if (dedupKey.length() > MAX_KEY) {
      dedupKey = name + ':' + sha256(Blob.valueOf(eventId));
    }
    Hook_Inbound_Event__c rec = new Hook_Inbound_Event__c(
      Endpoint__c = name,
      Event_Id__c = eventId.left(MAX_KEY),
      Event_Type__c = eventType == null ? null : eventType.left(MAX_KEY),
      Dedup_Key__c = dedupKey,
      Body__c = request.body,
      Headers__c = storedHeaders(request),
      Status__c = 'Pending',
      Attempts__c = 0,
      Received_At__c = HookClock.now()
    );
    Database.SaveResult saved = Database.insert(
      rec,
      false,
      AccessLevel.SYSTEM_MODE
    );
    if (!saved.isSuccess()) {
      if (isDuplicate(saved)) {
        return HookResponse.ofJson(
          200,
          new Map<String, Object>{
            'status' => 'duplicate',
            'eventId' => rec.Event_Id__c
          }
        );
      }
      throw new HookException(
        'Hook could not store the event: ' + saved.getErrors()[0].getMessage()
      );
    }
    HookInboundDispatcher.publish(new List<Id>{ saved.getId() });
    return HookResponse.ofJson(
      200,
      new Map<String, Object>{
        'status' => 'accepted',
        'eventId' => rec.Event_Id__c
      }
    );
  }

  /**
   * @description Tells if a save failed only because the dedup key exists.
   * @param saved The save result.
   * @return True for a duplicate.
   */
  public static Boolean isDuplicate(Database.SaveResult saved) {
    for (Database.Error err : saved.getErrors()) {
      if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
        return true;
      }
    }
    return false;
  }

  private static String storedHeaders(HookRequest request) {
    Map<String, String> kept = request.headers();
    for (String name : SECRET_HEADERS) {
      kept.remove(name);
    }
    return JSON.serialize(kept).left(32768);
  }

  private static String firstNonBlank(List<String> values) {
    for (String value : values) {
      if (String.isNotBlank(value)) {
        return value;
      }
    }
    return null;
  }

  private static String sha256(Blob data) {
    return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', data));
  }

  private static HookResponse error(Integer status, String message) {
    return HookResponse.ofJson(
      status,
      new Map<String, Object>{ 'status' => 'error', 'error' => message }
    );
  }
}
