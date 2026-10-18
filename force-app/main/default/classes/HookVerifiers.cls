/**
 * @description The built-in verifiers. Each one checks the raw body bytes.
 */
public inherited sharing class HookVerifiers {
  /** @description Default largest age of a signed timestamp, in seconds. */
  public static final Integer DEFAULT_TOLERANCE = 300;

  /**
   * @description Gives the verifier of an endpoint.
   * @param ep The endpoint.
   * @return The verifier.
   * @throws HookException For an unknown scheme or a bad custom class.
   */
  public static HookVerifier forEndpoint(Hook_Endpoint__mdt ep) {
    if (String.isNotBlank(ep.Verifier_Class__c)) {
      Object custom = HookTypes.make(ep.Verifier_Class__c, 'HookVerifier');
      if (!(custom instanceof HookVerifier)) {
        throw HookTypes.wrongType(ep.Verifier_Class__c, 'HookVerifier');
      }
      return (HookVerifier) custom;
    }
    Integer tolerance = ep.Tolerance_Seconds__c == null
      ? DEFAULT_TOLERANCE
      : ep.Tolerance_Seconds__c.intValue();
    String scheme = ep.Scheme__c == null
      ? ''
      : ep.Scheme__c.trim().toUpperCase();
    switch on scheme {
      when 'STANDARD_WEBHOOKS' {
        return new StandardWebhooks(tolerance);
      }
      when 'STRIPE' {
        return new Stripe(tolerance);
      }
      when 'GITHUB' {
        return new GitHub();
      }
      when 'SLACK' {
        return new Slack(tolerance);
      }
      when 'SHOPIFY' {
        return new Shopify();
      }
      when 'HMAC_SHA256' {
        return new Hmac(
          ep.Signature_Header__c,
          ep.Signature_Prefix__c,
          ep.Signature_Encoding__c
        );
      }
      when 'TOKEN' {
        return new Token(ep.Signature_Header__c, ep.Signature_Prefix__c);
      }
      when 'NONE' {
        return new NoCheck();
      }
      when else {
        throw new HookException(
          'Unknown scheme "' +
            ep.Scheme__c +
            '" on endpoint ' +
            ep.DeveloperName +
            '.'
        );
      }
    }
  }

  /**
   * @description Tells if the event Id of a verifier is in the signed data.
   * GitHub, Shopify, HMAC_SHA256, TOKEN and NONE take the Id from an unsigned
   * header. Hook trusts the Id of a custom verifier.
   * @param verifier The verifier.
   * @return True when the Id is signed.
   */
  public static Boolean signsEventId(HookVerifier verifier) {
    if (
      verifier instanceof StandardWebhooks ||
      verifier instanceof Stripe ||
      verifier instanceof Slack
    ) {
      return true;
    }
    return !(verifier instanceof Signed || verifier instanceof NoCheck);
  }

  private static String hexMac(String secret, Blob data) {
    return EncodingUtil.convertToHex(
      HookSigner.hmac(Blob.valueOf(secret), data)
    );
  }

  private static String base64Mac(String secret, Blob data) {
    return EncodingUtil.base64Encode(
      HookSigner.hmac(Blob.valueOf(secret), data)
    );
  }

  private static String lower(String value) {
    return value == null ? null : value.trim().toLowerCase();
  }

  // Gives the reason when the timestamp is bad or too old, else null.
  private static String timestampProblem(String raw, Integer tolerance) {
    if (String.isBlank(raw) || !Pattern.matches('[0-9]{1,12}', raw.trim())) {
      return 'The timestamp is missing or not a number.';
    }
    Long ts = Long.valueOf(raw.trim());
    if (Math.abs(HookClock.nowSeconds() - ts) > tolerance) {
      return 'The timestamp is outside the tolerance of ' + tolerance + ' s.';
    }
    return null;
  }

  // Reads "t=1,v1=a,v1=b" into t -> [1], v1 -> [a, b]. Values are lower case.
  private static Map<String, List<String>> parseStripeHeader(String header) {
    Map<String, List<String>> parts = new Map<String, List<String>>();
    for (
      String part : header == null ? new List<String>() : header.split(',')
    ) {
      String key = part.substringBefore('=').trim();
      if (!parts.containsKey(key)) {
        parts.put(key, new List<String>());
      }
      parts.get(key).add(part.substringAfter('=').trim().toLowerCase());
    }
    return parts;
  }

  /**
   * @description A verifier that needs at least one secret.
   */
  public abstract class Signed implements HookVerifier {
    /**
     * @description Verifies the request when a secret is set.
     * @param request The request.
     * @param secrets The secrets.
     * @return The result.
     */
    public HookVerification verify(HookRequest request, List<String> secrets) {
      if (secrets == null || secrets.isEmpty()) {
        return HookVerification.invalid('No secret is set for the endpoint.');
      }
      return check(request, secrets);
    }

    /**
     * @description Checks the signature.
     * @param request The request.
     * @param secrets The secrets. Not empty.
     * @return The result.
     */
    public abstract HookVerification check(
      HookRequest request,
      List<String> secrets
    );
  }

  /**
   * @description Standard Webhooks and Svix: webhook-id, webhook-timestamp and
   * webhook-signature over "id.timestamp.body". The key is base64 after whsec_.
   */
  public class StandardWebhooks extends Signed {
    private final Integer tolerance;

    /**
     * @description Makes the verifier.
     * @param tolerance Largest timestamp age, in seconds.
     */
    public StandardWebhooks(Integer tolerance) {
      this.tolerance = tolerance;
    }

    private String either(HookRequest request, String name) {
      String value = request.header('webhook-' + name);
      return value != null ? value : request.header('svix-' + name);
    }

    /**
     * @description Checks each v1 signature against each secret.
     * @param request The request.
     * @param secrets The secrets.
     * @return The result.
     */
    public override HookVerification check(
      HookRequest request,
      List<String> secrets
    ) {
      String id = either(request, 'id');
      String ts = either(request, 'timestamp');
      String signatures = either(request, 'signature');
      if (
        String.isBlank(id) ||
        String.isBlank(ts) ||
        String.isBlank(signatures)
      ) {
        return HookVerification.invalid(
          'A Standard Webhooks header is missing.'
        );
      }
      String problem = timestampProblem(ts, tolerance);
      if (problem != null) {
        return HookVerification.invalid(problem);
      }
      Blob data = HookSigner.concat(
        Blob.valueOf(id + '.' + ts.trim() + '.'),
        request.bodyBlob
      );
      for (String secret : secrets) {
        String expected;
        try {
          expected =
            'v1,' +
            EncodingUtil.base64Encode(
              HookSigner.hmac(HookSigner.standardKey(secret), data)
            );
        } catch (Exception e) {
          continue;
        }
        for (String given : signatures.trim().split('\\s+')) {
          if (HookSigner.equalsConstantTime(given, expected)) {
            return HookVerification.valid(
              id,
              HookJson.textAt(request.body, 'type')
            );
          }
        }
      }
      return HookVerification.invalid('No webhook-signature matches.');
    }
  }

  /**
   * @description Stripe: Stripe-Signature "t=...,v1=..." over "t.body". The key is the secret text.
   */
  public class Stripe extends Signed {
    private final Integer tolerance;

    /**
     * @description Makes the verifier.
     * @param tolerance Largest timestamp age, in seconds.
     */
    public Stripe(Integer tolerance) {
      this.tolerance = tolerance;
    }

    /**
     * @description Checks each v1 signature against each secret.
     * @param request The request.
     * @param secrets The secrets.
     * @return The result.
     */
    public override HookVerification check(
      HookRequest request,
      List<String> secrets
    ) {
      Map<String, List<String>> parts = parseStripeHeader(
        request.header('stripe-signature')
      );
      String ts = parts.containsKey('t') ? parts.get('t')[0] : null;
      List<String> given = parts.containsKey('v1')
        ? parts.get('v1')
        : new List<String>();
      if (String.isBlank(ts) || given.isEmpty()) {
        return HookVerification.invalid(
          'The Stripe-Signature header is missing or not valid.'
        );
      }
      String problem = timestampProblem(ts, tolerance);
      if (problem != null) {
        return HookVerification.invalid(problem);
      }
      Blob data = HookSigner.concat(Blob.valueOf(ts + '.'), request.bodyBlob);
      for (String secret : secrets) {
        String expected = hexMac(secret, data);
        for (String candidate : given) {
          if (HookSigner.equalsConstantTime(candidate, expected)) {
            return HookVerification.valid(
              HookJson.textAt(request.body, 'id'),
              HookJson.textAt(request.body, 'type')
            );
          }
        }
      }
      return HookVerification.invalid('No Stripe v1 signature matches.');
    }
  }

  /**
   * @description GitHub: X-Hub-Signature-256 "sha256=<hex>" over the body.
   */
  public class GitHub extends Signed {
    /**
     * @description Checks the signature against each secret.
     * @param request The request.
     * @param secrets The secrets.
     * @return The result.
     */
    public override HookVerification check(
      HookRequest request,
      List<String> secrets
    ) {
      String given = lower(request.header('x-hub-signature-256'));
      if (given == null || !given.startsWith('sha256=')) {
        return HookVerification.invalid(
          'The X-Hub-Signature-256 header is missing.'
        );
      }
      for (String secret : secrets) {
        if (
          HookSigner.equalsConstantTime(
            given,
            'sha256=' + hexMac(secret, request.bodyBlob)
          )
        ) {
          return HookVerification.valid(
            request.header('x-github-delivery'),
            request.header('x-github-event')
          );
        }
      }
      return HookVerification.invalid(
        'The X-Hub-Signature-256 header does not match.'
      );
    }
  }

  /**
   * @description Slack: X-Slack-Signature "v0=<hex>" over "v0:timestamp:body".
   * It answers url_verification with the challenge.
   */
  public class Slack extends Signed implements HookHandshake {
    private final Integer tolerance;

    /**
     * @description Makes the verifier.
     * @param tolerance Largest timestamp age, in seconds.
     */
    public Slack(Integer tolerance) {
      this.tolerance = tolerance;
    }

    /**
     * @description Checks the signature against each secret.
     * @param request The request.
     * @param secrets The secrets.
     * @return The result.
     */
    public override HookVerification check(
      HookRequest request,
      List<String> secrets
    ) {
      String ts = request.header('x-slack-request-timestamp');
      String given = lower(request.header('x-slack-signature'));
      if (String.isBlank(ts) || given == null) {
        return HookVerification.invalid('A Slack signature header is missing.');
      }
      String problem = timestampProblem(ts, tolerance);
      if (problem != null) {
        return HookVerification.invalid(problem);
      }
      Blob data = HookSigner.concat(
        Blob.valueOf('v0:' + ts.trim() + ':'),
        request.bodyBlob
      );
      for (String secret : secrets) {
        if (
          HookSigner.equalsConstantTime(given, 'v0=' + hexMac(secret, data))
        ) {
          String type = HookJson.textAt(request.body, 'event.type');
          return HookVerification.valid(
            HookJson.textAt(request.body, 'event_id'),
            type != null ? type : HookJson.textAt(request.body, 'type')
          );
        }
      }
      return HookVerification.invalid(
        'The X-Slack-Signature header does not match.'
      );
    }

    /**
     * @description Answers a url_verification request with its challenge.
     * @param request The verified request.
     * @param secrets The secrets.
     * @return The challenge as text, or null.
     */
    public HookResponse respond(HookRequest request, List<String> secrets) {
      if (
        request.method == 'POST' &&
        HookJson.textAt(request.body, 'type') == 'url_verification'
      ) {
        return new HookResponse(
          200,
          HookJson.textAt(request.body, 'challenge'),
          'text/plain'
        );
      }
      return null;
    }
  }

  /**
   * @description Shopify: X-Shopify-Hmac-Sha256, base64 over the body.
   */
  public class Shopify extends Signed {
    /**
     * @description Checks the signature against each secret.
     * @param request The request.
     * @param secrets The secrets.
     * @return The result.
     */
    public override HookVerification check(
      HookRequest request,
      List<String> secrets
    ) {
      String given = request.header('x-shopify-hmac-sha256');
      if (String.isBlank(given)) {
        return HookVerification.invalid(
          'The X-Shopify-Hmac-Sha256 header is missing.'
        );
      }
      for (String secret : secrets) {
        if (
          HookSigner.equalsConstantTime(
            given.trim(),
            base64Mac(secret, request.bodyBlob)
          )
        ) {
          String id = request.header('x-shopify-webhook-id');
          return HookVerification.valid(
            id != null ? id : request.header('x-shopify-event-id'),
            request.header('x-shopify-topic')
          );
        }
      }
      return HookVerification.invalid(
        'The X-Shopify-Hmac-Sha256 header does not match.'
      );
    }
  }

  /**
   * @description A generic HMAC-SHA256 over the body, in a configured header.
   */
  public class Hmac extends Signed {
    private final String header;
    private final String prefix;
    private final Boolean base64;

    /**
     * @description Makes the verifier.
     * @param header The signature header.
     * @param prefix Text before the signature, or null.
     * @param encoding hex (default) or base64.
     */
    public Hmac(String header, String prefix, String encoding) {
      this.header = header;
      this.prefix = prefix == null ? '' : prefix;
      this.base64 =
        encoding != null && encoding.trim().equalsIgnoreCase('base64');
    }

    /**
     * @description Checks the signature against each secret.
     * @param request The request.
     * @param secrets The secrets.
     * @return The result.
     */
    public override HookVerification check(
      HookRequest request,
      List<String> secrets
    ) {
      if (String.isBlank(header)) {
        return HookVerification.invalid(
          'No signature header is set for the endpoint.'
        );
      }
      String given = request.header(header);
      if (given == null || !given.trim().startsWith(prefix)) {
        return HookVerification.invalid(
          'The ' + header + ' header is missing.'
        );
      }
      given = given.trim().removeStart(prefix).trim();
      for (String secret : secrets) {
        String expected = base64
          ? base64Mac(secret, request.bodyBlob)
          : hexMac(secret, request.bodyBlob);
        if (
          HookSigner.equalsConstantTime(
            base64 ? given : given.toLowerCase(),
            expected
          )
        ) {
          return HookVerification.valid(null, null);
        }
      }
      return HookVerification.invalid(
        'The ' + header + ' header does not match.'
      );
    }
  }

  /**
   * @description A shared token in a header, for example "Authorization: Bearer <secret>".
   */
  public class Token extends Signed {
    private final String header;
    private final String prefix;

    /**
     * @description Makes the verifier.
     * @param header The header. Default Authorization.
     * @param prefix Text before the token, or null.
     */
    public Token(String header, String prefix) {
      this.header = String.isBlank(header) ? 'Authorization' : header;
      this.prefix = prefix == null ? '' : prefix;
    }

    /**
     * @description Compares the token with each secret.
     * @param request The request.
     * @param secrets The secrets.
     * @return The result.
     */
    public override HookVerification check(
      HookRequest request,
      List<String> secrets
    ) {
      String given = request.header(header);
      if (given == null || !given.startsWith(prefix)) {
        return HookVerification.invalid(
          'The ' + header + ' header is missing.'
        );
      }
      given = given.removeStart(prefix);
      for (String secret : secrets) {
        if (HookSigner.equalsConstantTime(given, secret)) {
          return HookVerification.valid(null, null);
        }
      }
      return HookVerification.invalid(
        'The ' + header + ' header does not match.'
      );
    }
  }

  /**
   * @description No check. Use it only for an authenticated caller or a test.
   */
  public class NoCheck implements HookVerifier {
    /**
     * @description Accepts the request.
     * @param request The request.
     * @param secrets The secrets.
     * @return A valid result.
     */
    public HookVerification verify(HookRequest request, List<String> secrets) {
      return HookVerification.valid(null, null);
    }
  }
}
