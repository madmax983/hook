/**
 * @description Tests for the inbound REST endpoint and the store (AC-IN-1,
 * AC-IN-4, AC-IN-6, AC-IN-7, AC-IN-10, AC-IN-11, AC-IN-14, AC-SEC-5).
 */
@IsTest
private class HookInboundTest {
  private static Map<String, Object> github;

  private static Map<String, String> githubHeaders(String deliveryId) {
    return new Map<String, String>{
      'X-Hub-Signature-256' => (String) github.get('header'),
      'X-GitHub-Delivery' => deliveryId,
      'X-GitHub-Event' => 'pull_request',
      'Authorization' => 'Bearer do-not-store',
      'Proxy-Authorization' => 'Basic do-not-store',
      'Cookie' => 'sid=do-not-store'
    };
  }

  private static void setUp() {
    github = HookTestSupport.vector('github');
    HookTestSupport.settings();
    HookTestSupport.endpoint('gh', 'GITHUB');
    HookTestSupport.secret(
      HookTestSupport.SECRET_NAME,
      (String) github.get('secret')
    );
  }

  private static HookResponse post(
    String endpoint,
    String body,
    Map<String, String> headers
  ) {
    return HookInbound.receive(
      HookTestSupport.request(endpoint, body, headers)
    );
  }

  private static Map<String, Object> parsed(HookResponse res) {
    return (Map<String, Object>) JSON.deserializeUntyped(res.body);
  }

  @IsTest
  static void aValidRequestStoresOneEventAndPublishes() {
    setUp();
    Test.startTest();
    HookResponse res = post(
      'gh',
      (String) github.get('body'),
      githubHeaders('d-1')
    );
    Test.stopTest();

    Assert.areEqual(200, res.statusCode, res.body);
    Assert.areEqual('accepted', parsed(res).get('status'));
    Hook_Inbound_Event__c rec = [
      SELECT
        Endpoint__c,
        Event_Id__c,
        Event_Type__c,
        Dedup_Key__c,
        Body__c,
        Headers__c,
        Status__c,
        Received_At__c
      FROM Hook_Inbound_Event__c
    ];
    Assert.areEqual('gh', rec.Endpoint__c);
    Assert.areEqual('d-1', rec.Event_Id__c);
    Assert.areEqual('pull_request', rec.Event_Type__c);
    Assert.areEqual(
      'gh:' + sha256((String) github.get('body')),
      rec.Dedup_Key__c,
      'X-GitHub-Delivery is not signed, so the key is the body hash'
    );
    Assert.areEqual((String) github.get('body'), rec.Body__c);
    Assert.isNotNull(rec.Received_At__c);
    Assert.isFalse(
      rec.Headers__c.containsIgnoreCase('do-not-store'),
      'AC-SEC-5'
    );
    Assert.isTrue(
      rec.Headers__c.contains('x-github-event'),
      'lower-case header names'
    );
    // The platform event ran the handler in Test.stopTest().
    Assert.areEqual(
      'Processed',
      [SELECT Status__c FROM Hook_Inbound_Event__c].Status__c
    );
    Assert.areEqual(1, HookTestSupport.seen.size());
    Assert.areEqual('pull_request', HookTestSupport.seen[0].eventType);
  }

  @IsTest
  static void aDuplicateStoresNothing() {
    setUp();
    Test.startTest();
    post('gh', (String) github.get('body'), githubHeaders('d-1'));
    HookResponse second = post(
      'gh',
      (String) github.get('body'),
      githubHeaders('d-1')
    );
    Test.stopTest();
    Assert.areEqual(200, second.statusCode);
    Assert.areEqual('duplicate', parsed(second).get('status'));
    Assert.areEqual(1, [SELECT COUNT() FROM Hook_Inbound_Event__c]);
  }

  @IsTest
  static void anUnknownOrInactiveEndpointGives404() {
    setUp();
    Assert.areEqual(
      404,
      post('missing', '{}', new Map<String, String>()).statusCode
    );
    Assert.areEqual(
      404,
      post('bad name!', '{}', new Map<String, String>()).statusCode
    );
    HookEndpoints.overrides.get('gh').Active__c = false;
    Assert.areEqual(
      404,
      post('gh', (String) github.get('body'), githubHeaders('d-1')).statusCode
    );
  }

  @IsTest
  static void aBadSignatureGives401AndStoresNothing() {
    setUp();
    HookResponse res = post(
      'gh',
      (String) github.get('body') + 'x',
      githubHeaders('d-1')
    );
    Assert.areEqual(401, res.statusCode);
    Assert.areEqual(0, [SELECT COUNT() FROM Hook_Inbound_Event__c]);
  }

  @IsTest
  static void aLargeBodyGives413AndBadUtf8Gives400() {
    setUp();
    HookEndpoints.overrides.get('gh').Scheme__c = 'NONE';
    String big = 'x'.repeat(HookInbound.MAX_BODY_CHARS + 1);
    Assert.areEqual(413, post('gh', big, new Map<String, String>()).statusCode);

    HookRequest bad = new HookRequest(
      'POST',
      'gh',
      EncodingUtil.convertFromHex('c328'),
      new Map<String, String>(),
      new Map<String, String>(),
      null
    );
    Assert.areEqual(400, HookInbound.receive(bad).statusCode);
  }

  @IsTest
  static void anEndpointWithNoIdUsesTheConfiguredPathOrTheBodyHash() {
    setUp();
    Hook_Endpoint__mdt ep = HookEndpoints.overrides.get('gh');
    ep.Scheme__c = 'NONE';
    ep.Event_Id_Path__c = 'data.id';
    ep.Event_Type_Path__c = 'kind';
    post(
      'gh',
      '{"kind":"thing.made","data":{"id":"t-9"}}',
      new Map<String, String>()
    );
    Hook_Inbound_Event__c rec = [
      SELECT Event_Id__c, Event_Type__c
      FROM Hook_Inbound_Event__c
    ];
    Assert.areEqual('t-9', rec.Event_Id__c);
    Assert.areEqual('thing.made', rec.Event_Type__c);

    ep.Event_Id_Path__c = null;
    ep.Event_Id_Header__c = 'X-Request-Id';
    post('gh', '{"a":1}', new Map<String, String>{ 'x-request-id' => 'r-1' });
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Hook_Inbound_Event__c WHERE Event_Id__c = 'r-1']
    );

    ep.Event_Id_Header__c = null;
    HookResponse first = post('gh', '{"b":2}', new Map<String, String>());
    HookResponse again = post('gh', '{"b":2}', new Map<String, String>());
    Assert.areEqual('accepted', parsed(first).get('status'));
    Assert.areEqual('duplicate', parsed(again).get('status'));
    Assert.areEqual(
      EncodingUtil.convertToHex(
        Crypto.generateDigest('SHA-256', Blob.valueOf('{"b":2}'))
      ),
      [
        SELECT Event_Id__c
        FROM Hook_Inbound_Event__c
        WHERE Event_Id__c NOT IN ('t-9', 'r-1')
      ]
      .Event_Id__c
    );
  }

  @IsTest
  static void aLongEventIdGivesAHashedDedupKey() {
    setUp();
    Hook_Endpoint__mdt ep = HookEndpoints.overrides.get('gh');
    ep.Scheme__c = 'NONE';
    ep.Event_Id_Header__c = 'X-Id';
    String longId = 'i'.repeat(300);
    post('gh', '{}', new Map<String, String>{ 'X-Id' => longId });
    Hook_Inbound_Event__c rec = [
      SELECT Event_Id__c, Dedup_Key__c
      FROM Hook_Inbound_Event__c
    ];
    Assert.areEqual(255, rec.Event_Id__c.length());
    Assert.isTrue(rec.Dedup_Key__c.length() <= 255);
    Assert.isTrue(rec.Dedup_Key__c.startsWith('gh:'));
  }

  @IsTest
  static void slackUrlVerificationGivesTheChallenge() {
    Map<String, Object> v = HookTestSupport.vector('slack');
    HookTestSupport.settings();
    HookTestSupport.endpoint('slack', 'SLACK');
    HookTestSupport.secret(
      HookTestSupport.SECRET_NAME,
      (String) v.get('secret')
    );
    HookClock.fixedSeconds = Long.valueOf(String.valueOf(v.get('timestamp')));
    HookResponse res = post(
      'slack',
      (String) v.get('challengeBody'),
      new Map<String, String>{
        'X-Slack-Request-Timestamp' => String.valueOf(v.get('timestamp')),
        'X-Slack-Signature' => (String) v.get('challengeSignature')
      }
    );
    Assert.areEqual(200, res.statusCode);
    Assert.areEqual('text/plain', res.contentType);
    Assert.areEqual(
      '3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P',
      res.body
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Hook_Inbound_Event__c]);
  }

  @IsTest
  static void aGetUsesTheHandlerHandshakeOrGives405() {
    setUp();
    HookRequest get = new HookRequest(
      'GET',
      'gh',
      null,
      new Map<String, String>(),
      new Map<String, String>{
        'hub.challenge' => 'abc',
        'hub.verify_token' => 'tok'
      },
      null
    );
    Assert.areEqual(405, HookInbound.receive(get).statusCode);

    HookEndpoints.overrides.get('gh')
      .Handler_Class__c = 'HookInboundTest.MetaHandler';
    HookResponse res = HookInbound.receive(get);
    Assert.areEqual(200, res.statusCode);
    Assert.areEqual('abc', res.body);
  }

  @IsTest
  static void anErrorGives500AndRollsBack() {
    setUp();
    HookEndpoints.overrides.get('gh')
      .Verifier_Class__c = 'HookInboundTest.ExplodingVerifier';
    HookResponse res = post('gh', '{}', new Map<String, String>());
    Assert.areEqual(500, res.statusCode);
    Assert.isFalse(
      res.body.contains('boom'),
      'no internal detail to the caller'
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Hook_Inbound_Event__c]);
  }

  @IsTest
  static void theRestResourceWritesTheResponse() {
    setUp();
    RestRequest req = new RestRequest();
    req.requestURI = '/hook/gh/';
    req.httpMethod = 'POST';
    req.requestBody = Blob.valueOf((String) github.get('body'));
    for (String key : githubHeaders('d-rest').keySet()) {
      req.addHeader(key, githubHeaders('d-rest').get(key));
    }
    RestContext.request = req;
    RestContext.response = new RestResponse();
    HookInboundResource.doPost();
    Assert.areEqual(200, RestContext.response.statusCode);
    Assert.areEqual(
      'application/json',
      RestContext.response.headers.get('Content-Type')
    );
    Assert.isTrue(
      RestContext.response.responseBody.toString().contains('accepted')
    );

    req.httpMethod = 'GET';
    req.requestBody = null;
    RestContext.response = new RestResponse();
    HookInboundResource.doGet();
    Assert.areEqual(405, RestContext.response.statusCode);
  }

  @IsTest
  static void endpointNameComesFromTheLastPathSegment() {
    Assert.areEqual('stripe', HookRequest.endpointFromUri('/hook/stripe'));
    Assert.areEqual('stripe', HookRequest.endpointFromUri('/hook/stripe/'));
    Assert.areEqual('stripe', HookRequest.endpointFromUri('/hook/stripe?x=1'));
    Assert.isNull(HookRequest.endpointFromUri('/hook/'));
    Assert.isNull(HookRequest.endpointFromUri(null));
  }

  /**
   * @description A handler with a GET handshake, as Meta uses.
   */
  public class MetaHandler implements HookInboundHandler, HookHandshake {
    /**
     * @description Does nothing.
     * @param event The event.
     */
    public void handle(HookInboundEvent event) {
      return;
    }

    /**
     * @description Echoes hub.challenge when hub.verify_token is correct.
     * @param request The request.
     * @param secrets The secrets.
     * @return The challenge, or null.
     */
    public HookResponse respond(HookRequest request, List<String> secrets) {
      if (
        request.method == 'GET' &&
        request.param('hub.verify_token') == 'tok'
      ) {
        return new HookResponse(
          200,
          request.param('hub.challenge'),
          'text/plain'
        );
      }
      return null;
    }
  }

  /**
   * @description A verifier that throws.
   */
  public class ExplodingVerifier implements HookVerifier {
    /**
     * @description Throws.
     * @param request The request.
     * @param secrets The secrets.
     * @return Never.
     */
    public HookVerification verify(HookRequest request, List<String> secrets) {
      throw new HookException('boom');
    }
  }

  private static String sha256(String text) {
    return EncodingUtil.convertToHex(
      Crypto.generateDigest('SHA-256', Blob.valueOf(text))
    );
  }

  @IsTest
  static void aReplayWithANewUnsignedIdIsADuplicate() {
    setUp();
    post('gh', (String) github.get('body'), githubHeaders('d-1'));
    HookResponse replay = post(
      'gh',
      (String) github.get('body'),
      githubHeaders('d-2')
    );
    Assert.areEqual('duplicate', parsed(replay).get('status'));
    Assert.areEqual(1, [SELECT COUNT() FROM Hook_Inbound_Event__c]);
  }

  @IsTest
  static void anUnsignedIdCannotBlockALaterEvent() {
    setUp();
    Hook_Endpoint__mdt ep = HookEndpoints.overrides.get('gh');
    ep.Scheme__c = 'NONE';
    ep.Event_Id_Header__c = 'X-Id';
    post('gh', '{"n":1}', new Map<String, String>{ 'X-Id' => 'evt-5' });
    HookResponse later = post(
      'gh',
      '{"n":2}',
      new Map<String, String>{ 'X-Id' => 'evt-5' }
    );
    Assert.areEqual('accepted', parsed(later).get('status'));
  }

  @IsTest
  static void aSignedIdIsTheDedupKey() {
    Map<String, Object> v = HookTestSupport.vector('stripe');
    HookTestSupport.settings();
    HookTestSupport.endpoint('stripe', 'STRIPE');
    HookTestSupport.secret(
      HookTestSupport.SECRET_NAME,
      (String) v.get('secret')
    );
    HookClock.fixedSeconds = Long.valueOf(String.valueOf(v.get('timestamp')));
    post(
      'stripe',
      (String) v.get('body'),
      new Map<String, String>{ 'Stripe-Signature' => (String) v.get('header') }
    );
    Assert.areEqual(
      'stripe:evt_1',
      [SELECT Dedup_Key__c FROM Hook_Inbound_Event__c].Dedup_Key__c
    );
  }

  @IsTest
  static void aGuestCannotUseAnEndpointWithNoCheck() {
    setUp();
    HookEndpoints.overrides.get('gh').Scheme__c = 'NONE';
    HookInbound.guestOverride = true;
    HookResponse res = post('gh', '{}', new Map<String, String>());
    Assert.areEqual(401, res.statusCode);
    Assert.areEqual(0, [SELECT COUNT() FROM Hook_Inbound_Event__c]);
  }

  @IsTest
  static void a401GivesNoReason() {
    setUp();
    HookResponse res = post('gh', '{}', new Map<String, String>());
    Assert.areEqual(401, res.statusCode);
    Assert.areEqual('unauthorized', parsed(res).get('error'));
  }

  @IsTest
  static void theTokenHeaderIsNotStored() {
    setUp();
    Hook_Endpoint__mdt ep = HookEndpoints.overrides.get('gh');
    ep.Scheme__c = 'TOKEN';
    ep.Signature_Header__c = 'X-Gitlab-Token';
    HookTestSupport.secret('tok', 'gl-secret');
    ep.Secret_Names__c = 'tok';
    post(
      'gh',
      '{}',
      new Map<String, String>{
        'X-Gitlab-Token' => 'gl-secret',
        'X-Api-Key' => 'k-1'
      }
    );
    String headers = [SELECT Headers__c FROM Hook_Inbound_Event__c].Headers__c;
    Assert.isFalse(headers.contains('gl-secret'), headers);
    Assert.isFalse(headers.contains('k-1'), headers);
  }

  @IsTest
  static void aBadHandlerIsNotMadeBeforeVerification() {
    setUp();
    HookEndpoints.overrides.get('gh')
      .Handler_Class__c = 'HookInboundTest.CountingHandler';
    made = 0;
    post('gh', '{}', new Map<String, String>());
    Assert.areEqual(
      0,
      made,
      'a request that fails verification makes no handler'
    );
  }

  /**
   * @description Counts its constructions.
   */
  public class CountingHandler implements HookInboundHandler {
    /**
     * @description Counts.
     */
    public CountingHandler() {
      made++;
    }

    /**
     * @description Does nothing.
     * @param event The event.
     */
    public void handle(HookInboundEvent event) {
      return;
    }
  }

  /** @description Constructions of CountingHandler. */
  public static Integer made = 0;

  @IsTest
  static void anOldTimestampGives401() {
    Map<String, Object> v = HookTestSupport.vector('stripe');
    HookTestSupport.settings();
    HookTestSupport.endpoint('stripe', 'STRIPE');
    HookTestSupport.secret(
      HookTestSupport.SECRET_NAME,
      (String) v.get('secret')
    );
    HookClock.fixedSeconds =
      Long.valueOf(String.valueOf(v.get('timestamp'))) + 301;
    HookResponse res = post(
      'stripe',
      (String) v.get('body'),
      new Map<String, String>{ 'Stripe-Signature' => (String) v.get('header') }
    );
    Assert.areEqual(401, res.statusCode, 'the default tolerance is 300 s');
  }

  @IsTest
  static void aGetUsesTheVerifierHandshake() {
    setUp();
    HookEndpoints.overrides.get('gh')
      .Verifier_Class__c = 'HookInboundTest.ChallengeVerifier';
    HookRequest get = new HookRequest(
      'GET',
      'gh',
      null,
      new Map<String, String>(),
      new Map<String, String>{ 'challenge' => 'c-1' },
      null
    );
    HookResponse res = HookInbound.receive(get);
    Assert.areEqual(200, res.statusCode);
    Assert.areEqual('c-1', res.body);
  }

  @IsTest
  static void anErrorAfterDmlRollsBack() {
    setUp();
    HookEndpoints.overrides.get('gh')
      .Verifier_Class__c = 'HookInboundTest.DmlThenThrowVerifier';
    HookResponse res = post('gh', '{}', new Map<String, String>());
    Assert.areEqual(500, res.statusCode);
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Hook_Secret__c WHERE Name = 'from_verifier']
    );
  }

  /**
   * @description A verifier with a GET challenge.
   */
  public class ChallengeVerifier implements HookVerifier, HookHandshake {
    /**
     * @description Accepts.
     * @param request The request.
     * @param secrets The secrets.
     * @return A valid result.
     */
    public HookVerification verify(HookRequest request, List<String> secrets) {
      return HookVerification.valid(null, null);
    }

    /**
     * @description Echoes the challenge parameter.
     * @param request The request.
     * @param secrets The secrets.
     * @return The challenge, or null.
     */
    public HookResponse respond(HookRequest request, List<String> secrets) {
      return request.param('challenge') == null
        ? null
        : new HookResponse(200, request.param('challenge'), 'text/plain');
    }
  }

  /**
   * @description A verifier that does DML, then throws.
   */
  public class DmlThenThrowVerifier implements HookVerifier {
    /**
     * @description Inserts, then throws.
     * @param request The request.
     * @param secrets The secrets.
     * @return Never.
     */
    public HookVerification verify(HookRequest request, List<String> secrets) {
      insert new Hook_Secret__c(Name = 'from_verifier', Value__c = 'x');
      throw new HookException('after DML');
    }
  }

  @IsTest
  static void theBodyDecodesWhenARequestIsRead() {
    HookRequest ok = HookTestSupport.request('x', 'caf\u00e9', null);
    Assert.areEqual(
      'caf\u00e9',
      ok.body,
      'a verifier can read the body with no decodeBody()'
    );
    HookRequest bad = new HookRequest(
      'POST',
      'x',
      EncodingUtil.convertFromHex('c328'),
      null,
      null,
      null
    );
    Assert.isNull(bad.body);
  }

  @IsTest
  static void anUnknownEndpointReadsNoRecord() {
    Assert.isNull(HookEndpoints.get('Hook_No_Such_Endpoint'));
  }
}
