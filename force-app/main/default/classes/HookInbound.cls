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
    'proxy-authorization',
    'x-api-key'
  };

  /** @description Tests set it to act as the Site guest user. */
  @TestVisible
  private static Boolean guestOverride;

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
      log(e);
      return error(500, 'internal error');
    }
  }

  // Writes the error to the debug log. The caller gets no detail.
  @SuppressWarnings('PMD.AvoidDebugStatements')
  private static void log(Exception e) {
    System.debug(
      LoggingLevel.ERROR,
      'Hook inbound error: ' + e.getMessage() + '\n' + e.getStackTraceString()
    );
  }

  private static HookResponse handle(HookRequest request) {
    Hook_Endpoint__mdt ep = HookEndpoints.get(request.endpoint);
    if (ep == null || ep.Active__c != true) {
      return error(404, 'unknown endpoint');
    }
    HookResponse bad = bodyProblem(request);
    if (bad != null) {
      return bad;
    }
    List<String> secrets = HookSecrets.valuesFor(ep.Secret_Names__c);
    HookVerifier verifier = HookVerifiers.forEndpoint(ep);
    if (request.method == 'GET') {
      HookResponse answer = handshake(
        new List<Object>{ verifier, handlerOrNull(ep) },
        request,
        secrets
      );
      return answer != null ? answer : error(405, 'method not allowed');
    }
    if (verifier instanceof HookVerifiers.NoCheck && isGuest()) {
      return unauthorized('The scheme NONE is not allowed for the guest user.');
    }
    HookVerification verification = verifier.verify(request, secrets);
    if (verification == null || verification.isValid != true) {
      return unauthorized(
        verification == null ? 'not verified' : verification.reason
      );
    }
    // Make the handler only after a valid verification.
    HookResponse answer = handshake(
      new List<Object>{ verifier, handlerOrNull(ep) },
      request,
      secrets
    );
    return answer != null
      ? answer
      : store(ep, request, verification, HookVerifiers.signsEventId(verifier));
  }

  private static Boolean isGuest() {
    return guestOverride != null
      ? guestOverride
      : UserInfo.getUserType() == 'Guest';
  }

  // Gives 401 with no detail. The reason goes to the debug log.
  private static HookResponse unauthorized(String reason) {
    logReason(reason);
    return error(401, 'unauthorized');
  }

  @SuppressWarnings('PMD.AvoidDebugStatements')
  private static void logReason(String reason) {
    System.debug(LoggingLevel.WARN, 'Hook inbound 401: ' + reason);
  }

  // Gives 413 or 400 for a body that Hook cannot store, else null.
  private static HookResponse bodyProblem(HookRequest request) {
    if (request.bodyBlob.size() > MAX_BODY_CHARS * 4) {
      return error(413, 'body too large');
    }
    if (!request.decodeBody()) {
      return error(400, 'body is not UTF-8');
    }
    return request.body.length() > MAX_BODY_CHARS
      ? error(413, 'body too large')
      : null;
  }

  // The handler, only to find a handshake. A bad handler class does not stop
  // the store: the dispatcher fails the row with the error.
  private static Object handlerOrNull(Hook_Endpoint__mdt ep) {
    try {
      return String.isBlank(ep.Handler_Class__c)
        ? null
        : HookTypes.make(ep.Handler_Class__c, 'HookInboundHandler');
    } catch (HookException e) {
      return null;
    }
  }

  private static HookResponse handshake(
    List<Object> candidates,
    HookRequest request,
    List<String> secrets
  ) {
    for (Object candidate : candidates) {
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

  // The dedup key uses only a signed value: an Id that the verifier signs, or
  // a path in the signed body, or the body hash. An unsigned header Id cannot
  // make a replay new, and cannot block a later event.
  private static HookResponse store(
    Hook_Endpoint__mdt ep,
    HookRequest request,
    HookVerification v,
    Boolean idIsSigned
  ) {
    String pathId = HookJson.textAt(request.body, ep.Event_Id_Path__c);
    String bodyHash = sha256(request.bodyBlob);
    String signedId = firstNonBlank(
      new List<String>{ idIsSigned ? v.eventId : null, pathId, bodyHash }
    );
    String eventId = firstNonBlank(
      new List<String>{
        v.eventId,
        request.header(ep.Event_Id_Header__c),
        pathId,
        bodyHash
      }
    );
    String eventType = firstNonBlank(
      new List<String>{
        v.eventType,
        request.header(ep.Event_Type_Header__c),
        HookJson.textAt(request.body, ep.Event_Type_Path__c)
      }
    );
    String name = ep.DeveloperName;
    String dedupKey = name + ':' + signedId;
    if (dedupKey.length() > MAX_KEY) {
      dedupKey = name + ':' + sha256(Blob.valueOf(signedId));
    }
    Hook_Inbound_Event__c rec = new Hook_Inbound_Event__c(
      Endpoint__c = name,
      Event_Id__c = eventId.left(MAX_KEY),
      Event_Type__c = eventType == null ? null : eventType.left(MAX_KEY),
      Dedup_Key__c = dedupKey,
      Body__c = request.body,
      Headers__c = storedHeaders(request, ep),
      Status__c = 'Pending',
      Attempts__c = 0,
      Received_At__c = HookClock.now(),
      Dispatched_At__c = HookClock.now()
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
    HookInboundDispatcher.publish(new List<Hook_Inbound_Event__c>{ rec });
    if (rec.Dispatched_At__c == null) {
      // The publish failed. The sweep publishes the row again.
      update as system new Hook_Inbound_Event__c(
        Id = rec.Id,
        Dispatched_At__c = null
      );
    }
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

  private static String storedHeaders(
    HookRequest request,
    Hook_Endpoint__mdt ep
  ) {
    Map<String, String> kept = request.headers();
    for (String name : SECRET_HEADERS) {
      kept.remove(name);
    }
    // The TOKEN scheme sends the secret itself in this header.
    if (String.isNotBlank(ep.Signature_Header__c)) {
      kept.remove(ep.Signature_Header__c.trim().toLowerCase());
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
