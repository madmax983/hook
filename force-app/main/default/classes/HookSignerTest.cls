/**
 * @description Tests for HookSigner: Standard Webhooks signatures, HMAC and the
 * constant-time compare. The expected values come from HookTestVectors.
 */
@IsTest
private class HookSignerTest {
  @IsTest
  static void standardSignatureEqualsEachVector() {
    for (
      Object raw : (List<Object>) HookTestSupport.vectors()
        .get('standardWebhooks')
    ) {
      Map<String, Object> v = (Map<String, Object>) raw;
      String actual = HookSigner.standardSignature(
        (String) v.get('secret'),
        (String) v.get('id'),
        Long.valueOf(String.valueOf(v.get('timestamp'))),
        (String) v.get('body')
      );
      Assert.areEqual(
        (String) v.get('signature'),
        actual,
        (String) v.get('name')
      );
    }
  }

  @IsTest
  static void hmacGivesHexAndBase64() {
    Map<String, Object> v = HookTestSupport.vector('hmac');
    Blob mac = HookSigner.hmac(
      Blob.valueOf((String) v.get('secret')),
      Blob.valueOf((String) v.get('body'))
    );
    Assert.areEqual((String) v.get('hex'), EncodingUtil.convertToHex(mac));
    Assert.areEqual((String) v.get('base64'), EncodingUtil.base64Encode(mac));
  }

  @IsTest
  static void concatKeepsTheBytes() {
    Blob joined = HookSigner.concat(Blob.valueOf('a.'), Blob.valueOf('café'));
    Assert.areEqual('a.café', joined.toString());
    Assert.areEqual(Blob.valueOf('a.café').size(), joined.size());
  }

  @IsTest
  static void standardKeyDecodesWhsecAndKeepsPlainText() {
    Assert.areEqual(
      'abc',
      HookSigner.standardKey(
          'whsec_' + EncodingUtil.base64Encode(Blob.valueOf('abc'))
        )
        .toString()
    );
    Assert.areEqual('plain', HookSigner.standardKey('plain').toString());
  }

  @IsTest
  static void signatureHeaderHasOneEntryForEachSecret() {
    String header = HookSigner.signatureHeader(
      new List<String>{
        'whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw',
        'whsec_c2Vjb25k'
      },
      'msg_1',
      1700000000L,
      '{}'
    );
    List<String> parts = header.split(' ');
    Assert.areEqual(2, parts.size());
    Assert.isTrue(parts[0].startsWith('v1,'));
    Assert.isTrue(parts[1].startsWith('v1,'));
    Assert.areNotEqual(parts[0], parts[1]);
  }

  @IsTest
  static void constantTimeEqualsComparesTheWholeValue() {
    Assert.isTrue(HookSigner.equalsConstantTime('abc', 'abc'));
    Assert.isFalse(HookSigner.equalsConstantTime('abc', 'abd'));
    Assert.isFalse(HookSigner.equalsConstantTime('abc', 'ab'));
    Assert.isFalse(HookSigner.equalsConstantTime(null, 'abc'));
    Assert.isFalse(HookSigner.equalsConstantTime('abc', null));
    Assert.isTrue(HookSigner.equalsConstantTime('', ''));
  }
}
