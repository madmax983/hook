/**
 * @description HMAC-SHA256 signatures and the Standard Webhooks format.
 * See https://www.standardwebhooks.com.
 */
public inherited sharing class HookSigner {
  /**
   * @description Gives the HMAC-SHA256 of the data.
   * @param key The key bytes.
   * @param data The data bytes.
   * @return The MAC bytes.
   */
  public static Blob hmac(Blob key, Blob data) {
    return Crypto.generateMac('hmacSHA256', data, key);
  }

  /**
   * @description Joins two byte sequences with no change to the bytes.
   * @param first The first bytes.
   * @param second The second bytes.
   * @return The joined bytes.
   */
  public static Blob concat(Blob first, Blob second) {
    String hex =
      (first == null ? '' : EncodingUtil.convertToHex(first)) +
      (second == null ? '' : EncodingUtil.convertToHex(second));
    return EncodingUtil.convertFromHex(hex);
  }

  /**
   * @description Gives the key bytes of a Standard Webhooks secret. A whsec_
   * secret is base64 after the prefix. Other text is used as UTF-8.
   * @param secret The secret.
   * @return The key bytes.
   */
  public static Blob standardKey(String secret) {
    if (secret != null && secret.startsWith('whsec_')) {
      return EncodingUtil.base64Decode(secret.removeStart('whsec_'));
    }
    return Blob.valueOf(secret == null ? '' : secret);
  }

  /**
   * @description Gives one Standard Webhooks signature over "id.timestamp.body".
   * @param secret The secret.
   * @param id The webhook-id.
   * @param timestamp The webhook-timestamp, in Unix seconds.
   * @param body The body.
   * @return The signature, "v1," and base64.
   */
  @SuppressWarnings('PMD.ExcessiveParameterList')
  public static String standardSignature(
    String secret,
    String id,
    Long timestamp,
    String body
  ) {
    return standardSignature(
      secret,
      id,
      timestamp,
      Blob.valueOf(body == null ? '' : body)
    );
  }

  /**
   * @description Gives one Standard Webhooks signature over the raw body bytes.
   * @param secret The secret.
   * @param id The webhook-id.
   * @param timestamp The webhook-timestamp, in Unix seconds.
   * @param body The body bytes.
   * @return The signature, "v1," and base64.
   */
  @SuppressWarnings('PMD.ExcessiveParameterList')
  public static String standardSignature(
    String secret,
    String id,
    Long timestamp,
    Blob body
  ) {
    Blob data = concat(Blob.valueOf(id + '.' + timestamp + '.'), body);
    return 'v1,' + EncodingUtil.base64Encode(hmac(standardKey(secret), data));
  }

  /**
   * @description Gives the webhook-signature header: one signature for each secret.
   * @param secrets The secrets.
   * @param id The webhook-id.
   * @param timestamp The webhook-timestamp.
   * @param body The body.
   * @return The signatures, separated by spaces.
   */
  @SuppressWarnings('PMD.ExcessiveParameterList')
  public static String signatureHeader(
    List<String> secrets,
    String id,
    Long timestamp,
    String body
  ) {
    List<String> parts = new List<String>();
    for (String secret : secrets) {
      parts.add(standardSignature(secret, id, timestamp, body));
    }
    return String.join(parts, ' ');
  }

  /**
   * @description Compares two values in a time that does not depend on where
   * they differ. The time depends only on the length.
   * @param a The first value.
   * @param b The second value.
   * @return True when both are not null and equal.
   */
  public static Boolean equalsConstantTime(String a, String b) {
    if (a == null || b == null) {
      return false;
    }
    Integer diff = a.length() ^ b.length();
    Integer len = Math.min(a.length(), b.length());
    for (Integer i = 0; i < len; i++) {
      diff |= a.charAt(i) ^ b.charAt(i);
    }
    return diff == 0;
  }
}
