/**
 * @description Tests for the built-in verifiers (AC-IN-2, AC-IN-3, AC-IN-4,
 * AC-IN-5, AC-SEC-3). The signatures come from HookTestVectors.
 */
@IsTest
private class HookVerifiersTest {
  @SuppressWarnings('PMD.ExcessiveParameterList')
  private static HookVerification run(
    Hook_Endpoint__mdt ep,
    String body,
    Map<String, String> headers,
    List<String> secrets
  ) {
    return HookVerifiers.forEndpoint(ep)
      .verify(
        HookTestSupport.request(ep.DeveloperName, body, headers),
        secrets
      );
  }

  private static List<String> one(Object secret) {
    return new List<String>{ (String) secret };
  }

  private static Long ts(Map<String, Object> v) {
    return Long.valueOf(String.valueOf(v.get('timestamp')));
  }

  @IsTest
  static void standardWebhooksAcceptsTheSpecVector() {
    Map<String, Object> v = (Map<String, Object>) ((List<Object>) HookTestSupport.vectors()
      .get('standardWebhooks'))[0];
    HookClock.fixedSeconds = ts(v) + 10;
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint(
      'std',
      'STANDARD_WEBHOOKS'
    );
    Map<String, String> headers = new Map<String, String>{
      'Webhook-Id' => (String) v.get('id'),
      'WEBHOOK-TIMESTAMP' => String.valueOf(v.get('timestamp')),
      'webhook-signature' => 'v1,bm90LXRoaXMtb25l ' +
      (String) v.get('signature')
    };
    HookVerification ok = run(
      ep,
      (String) v.get('body'),
      headers,
      one(v.get('secret'))
    );
    Assert.isTrue(ok.isValid, ok.reason);
    Assert.areEqual((String) v.get('id'), ok.eventId);

    Assert.isFalse(
      run(ep, '{"test": 1}', headers, one(v.get('secret'))).isValid,
      'changed body'
    );
    Assert.isFalse(
      run(ep, (String) v.get('body'), headers, one('whsec_d3Jvbmc=')).isValid,
      'wrong secret'
    );

    HookClock.fixedSeconds = ts(v) + 301;
    HookVerification stale = run(
      ep,
      (String) v.get('body'),
      headers,
      one(v.get('secret'))
    );
    Assert.isFalse(stale.isValid);
    Assert.isTrue(stale.reason.contains('tolerance'), stale.reason);
  }

  @IsTest
  static void standardWebhooksAcceptsSvixHeadersAndAPreviousSecret() {
    Map<String, Object> v = (Map<String, Object>) ((List<Object>) HookTestSupport.vectors()
      .get('standardWebhooks'))[1];
    HookClock.fixedSeconds = ts(v);
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint(
      'svix',
      'STANDARD_WEBHOOKS'
    );
    Map<String, String> headers = new Map<String, String>{
      'svix-id' => (String) v.get('id'),
      'svix-timestamp' => String.valueOf(v.get('timestamp')),
      'svix-signature' => (String) v.get('signature')
    };
    HookVerification ok = run(
      ep,
      (String) v.get('body'),
      headers,
      new List<String>{ 'whsec_bmV3LXNlY3JldA==', (String) v.get('secret') }
    );
    Assert.isTrue(ok.isValid, ok.reason);
  }

  @IsTest
  static void standardWebhooksRejectsMissingHeaders() {
    HookClock.fixedSeconds = 1700000000L;
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint(
      'std',
      'STANDARD_WEBHOOKS'
    );
    HookVerification v = run(
      ep,
      '{}',
      new Map<String, String>(),
      one('whsec_eA==')
    );
    Assert.isFalse(v.isValid);
    Assert.isTrue(v.reason.contains('header'), v.reason);
  }

  @IsTest
  static void stripeChecksTheV1SignatureAndTheTimestamp() {
    Map<String, Object> v = HookTestSupport.vector('stripe');
    HookClock.fixedSeconds = ts(v) - 100;
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('stripe', 'STRIPE');
    Map<String, String> headers = new Map<String, String>{
      'stripe-signature' => (String) v.get('header')
    };
    HookVerification ok = run(
      ep,
      (String) v.get('body'),
      headers,
      one(v.get('secret'))
    );
    Assert.isTrue(ok.isValid, ok.reason);
    Assert.areEqual('evt_1', ok.eventId);
    Assert.areEqual('payment_intent.succeeded', ok.eventType);

    Assert.isFalse(
      run(ep, (String) v.get('body') + ' ', headers, one(v.get('secret')))
        .isValid
    );
    ep.Tolerance_Seconds__c = 50;
    Assert.isFalse(
      run(ep, (String) v.get('body'), headers, one(v.get('secret'))).isValid
    );
    Assert.isFalse(
      run(
          ep,
          (String) v.get('body'),
          new Map<String, String>{ 'Stripe-Signature' => 't=x' },
          one(v.get('secret'))
        )
        .isValid
    );
  }

  @IsTest
  static void githubChecksTheSha256Header() {
    Map<String, Object> v = HookTestSupport.vector('github');
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('gh', 'GITHUB');
    Map<String, String> headers = new Map<String, String>{
      'X-Hub-Signature-256' => (String) v.get('header'),
      'X-GitHub-Delivery' => '72d3162e-cc78-11e3-81ab-4c9367dc0958',
      'X-GitHub-Event' => 'pull_request'
    };
    HookVerification ok = run(
      ep,
      (String) v.get('body'),
      headers,
      one(v.get('secret'))
    );
    Assert.isTrue(ok.isValid, ok.reason);
    Assert.areEqual('72d3162e-cc78-11e3-81ab-4c9367dc0958', ok.eventId);
    Assert.areEqual('pull_request', ok.eventType);

    HookVerification hello = run(
      ep,
      'Hello, World!',
      new Map<String, String>{
        'x-hub-signature-256' => (String) v.get('helloWorldHeader')
      },
      one(v.get('secret'))
    );
    Assert.isTrue(hello.isValid, 'published GitHub example');
    Assert.isFalse(
      run(ep, 'Hello, World?', headers, one(v.get('secret'))).isValid
    );
  }

  @IsTest
  static void slackChecksTheV0SignatureAndAnswersTheChallenge() {
    Map<String, Object> v = HookTestSupport.vector('slack');
    HookClock.fixedSeconds = ts(v);
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('slack', 'SLACK');
    Map<String, String> headers = new Map<String, String>{
      'X-Slack-Request-Timestamp' => String.valueOf(v.get('timestamp')),
      'X-Slack-Signature' => (String) v.get('eventSignature')
    };
    HookVerification ok = run(
      ep,
      (String) v.get('eventBody'),
      headers,
      one(v.get('secret'))
    );
    Assert.isTrue(ok.isValid, ok.reason);
    Assert.areEqual('Ev01', ok.eventId);
    Assert.areEqual('app_mention', ok.eventType);

    HookVerifier verifier = HookVerifiers.forEndpoint(ep);
    Assert.isTrue(verifier instanceof HookHandshake);
    headers.put('X-Slack-Signature', (String) v.get('challengeSignature'));
    HookRequest challenge = HookTestSupport.request(
      'slack',
      (String) v.get('challengeBody'),
      headers
    );
    Assert.isTrue(verifier.verify(challenge, one(v.get('secret'))).isValid);
    HookResponse res = ((HookHandshake) verifier)
      .respond(challenge, one(v.get('secret')));
    Assert.areEqual(200, res.statusCode);
    Assert.areEqual(
      '3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P',
      res.body
    );
    Assert.isNull(
      ((HookHandshake) verifier)
        .respond(
          HookTestSupport.request(
            'slack',
            (String) v.get('eventBody'),
            headers
          ),
          one(v.get('secret'))
        )
    );

    HookClock.fixedSeconds = ts(v) + 1000;
    headers.put('X-Slack-Signature', (String) v.get('eventSignature'));
    Assert.isFalse(
      run(ep, (String) v.get('eventBody'), headers, one(v.get('secret')))
        .isValid
    );
  }

  @IsTest
  static void shopifyChecksTheBase64Header() {
    Map<String, Object> v = HookTestSupport.vector('shopify');
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('shop', 'SHOPIFY');
    Map<String, String> headers = new Map<String, String>{
      'X-Shopify-Hmac-Sha256' => (String) v.get('header'),
      'X-Shopify-Webhook-Id' => 'b54557e4',
      'X-Shopify-Topic' => 'orders/create'
    };
    HookVerification ok = run(
      ep,
      (String) v.get('body'),
      headers,
      one(v.get('secret'))
    );
    Assert.isTrue(ok.isValid, ok.reason);
    Assert.areEqual('b54557e4', ok.eventId);
    Assert.areEqual('orders/create', ok.eventType);
    Assert.isFalse(run(ep, '{}', headers, one(v.get('secret'))).isValid);
  }

  @IsTest
  static void genericHmacUsesTheConfiguredHeaderPrefixAndEncoding() {
    Map<String, Object> v = HookTestSupport.vector('hmac');
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('generic', 'HMAC_SHA256');
    ep.Signature_Header__c = 'X-Signature';
    ep.Signature_Prefix__c = 'sha256=';
    HookVerification hex = run(
      ep,
      (String) v.get('body'),
      new Map<String, String>{
        'x-signature' => 'sha256=' + ((String) v.get('hex')).toUpperCase()
      },
      one(v.get('secret'))
    );
    Assert.isTrue(hex.isValid, hex.reason);

    ep.Signature_Prefix__c = null;
    ep.Signature_Encoding__c = 'base64';
    HookVerification b64 = run(
      ep,
      (String) v.get('body'),
      new Map<String, String>{ 'X-Signature' => (String) v.get('base64') },
      one(v.get('secret'))
    );
    Assert.isTrue(b64.isValid, b64.reason);

    ep.Signature_Header__c = null;
    Assert.isFalse(
      run(
          ep,
          (String) v.get('body'),
          new Map<String, String>(),
          one(v.get('secret'))
        )
        .isValid
    );
  }

  @IsTest
  static void tokenComparesTheHeaderToTheSecret() {
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('token', 'TOKEN');
    ep.Signature_Header__c = 'Authorization';
    ep.Signature_Prefix__c = 'Bearer ';
    Assert.isTrue(
      run(
          ep,
          '{}',
          new Map<String, String>{ 'authorization' => 'Bearer s3cret' },
          one('s3cret')
        )
        .isValid
    );
    Assert.isFalse(
      run(
          ep,
          '{}',
          new Map<String, String>{ 'authorization' => 'Bearer nope' },
          one('s3cret')
        )
        .isValid
    );
  }

  @IsTest
  static void noneAcceptsAndAnUnknownSchemeThrows() {
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('open', 'NONE');
    Assert.isTrue(
      run(ep, '{}', new Map<String, String>(), new List<String>()).isValid
    );

    ep.Scheme__c = 'NOPE';
    try {
      HookVerifiers.forEndpoint(ep);
      Assert.fail('Expected a HookException');
    } catch (HookException e) {
      Assert.isTrue(e.getMessage().contains('NOPE'), e.getMessage());
    }
  }

  @IsTest
  static void aSchemeWithASignatureNeedsASecret() {
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('gh', 'GITHUB');
    HookVerification v = run(
      ep,
      '{}',
      new Map<String, String>{ 'X-Hub-Signature-256' => 'sha256=00' },
      new List<String>()
    );
    Assert.isFalse(v.isValid);
    Assert.isTrue(v.reason.contains('secret'), v.reason);
  }

  @IsTest
  static void aCustomVerifierClassIsUsed() {
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('custom', null);
    ep.Verifier_Class__c = 'HookVerifiersTest.AllowVerifier';
    HookVerification v = run(
      ep,
      '{}',
      new Map<String, String>(),
      new List<String>()
    );
    Assert.isTrue(v.isValid);
    Assert.areEqual('custom-id', v.eventId);

    ep.Verifier_Class__c = 'HookVerifiersTest';
    try {
      HookVerifiers.forEndpoint(ep);
      Assert.fail('Expected a HookException');
    } catch (HookException e) {
      Assert.isTrue(e.getMessage().contains('HookVerifier'), e.getMessage());
    }
  }

  /**
   * @description A custom verifier for the test.
   */
  public class AllowVerifier implements HookVerifier {
    /**
     * @description Accepts each request.
     * @param request The request.
     * @param secrets The secrets.
     * @return A valid result.
     */
    public HookVerification verify(HookRequest request, List<String> secrets) {
      return HookVerification.valid('custom-id', 'custom.type');
    }
  }

  @IsTest
  static void tokenUsesAuthorizationByDefault() {
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('token', 'TOKEN');
    Assert.isTrue(
      run(
          ep,
          '{}',
          new Map<String, String>{ 'Authorization' => 's3cret' },
          one('s3cret')
        )
        .isValid
    );
  }

  @IsTest
  static void theSignatureCoversTheRawBytes() {
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('generic', 'HMAC_SHA256');
    ep.Signature_Header__c = 'X-Signature';
    String raw = '{ "a" :  1 }';
    String hex = EncodingUtil.convertToHex(
      Crypto.generateMac('hmacSHA256', Blob.valueOf(raw), Blob.valueOf('k'))
    );
    Map<String, String> headers = new Map<String, String>{
      'X-Signature' => hex
    };
    Assert.isTrue(run(ep, raw, headers, one('k')).isValid, 'the bytes as sent');
    String reserialized = JSON.serialize(JSON.deserializeUntyped(raw));
    Assert.isFalse(
      run(ep, reserialized, headers, one('k')).isValid,
      'not a new serialization'
    );
  }

  @IsTest
  static void aBadTimestampIsInvalidAndDoesNotThrow() {
    HookClock.fixedSeconds = 1700000000L;
    Hook_Endpoint__mdt ep = HookTestSupport.endpoint('slack', 'SLACK');
    HookVerification v = run(
      ep,
      '{}',
      new Map<String, String>{
        'X-Slack-Request-Timestamp' => '9'.repeat(25),
        'X-Slack-Signature' => 'v0=00'
      },
      one('s')
    );
    Assert.isFalse(v.isValid);
  }
}
