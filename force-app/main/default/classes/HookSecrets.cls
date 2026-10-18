/**
 * @description Reads and writes signing secrets in the protected Custom Setting
 * Hook_Secret__c (ADR 0003).
 */
public inherited sharing class HookSecrets {
  /** @description Largest secret name. It is the Custom Setting name limit. */
  public static final Integer MAX_NAME = 38;

  /**
   * @description Gives the active values for a list of secret names. For each
   * name: the current value, then the previous value until it expires.
   * @param names Secret names, separated by commas.
   * @return The values. A missing name gives no value.
   */
  public static List<String> valuesFor(String names) {
    List<String> values = new List<String>();
    if (String.isBlank(names)) {
      return values;
    }
    Datetime now = HookClock.now();
    for (String raw : names.split(',')) {
      Hook_Secret__c rec = String.isBlank(raw)
        ? null
        : Hook_Secret__c.getInstance(raw.trim());
      if (rec == null) {
        continue;
      }
      if (String.isNotBlank(rec.Value__c)) {
        values.add(rec.Value__c);
      }
      if (
        String.isNotBlank(rec.Previous_Value__c) &&
        rec.Previous_Expires_At__c != null &&
        rec.Previous_Expires_At__c > now
      ) {
        values.add(rec.Previous_Value__c);
      }
    }
    return values;
  }

  /**
   * @description Sets the current value of a secret. It makes the record when
   * it is missing. It removes the previous value at once, so use it to revoke
   * a leaked secret. To change a secret with no downtime, use rotate().
   * @param name The secret name.
   * @param value The value.
   */
  public static void put(String name, String value) {
    Hook_Secret__c rec = load(name);
    rec.Value__c = value;
    rec.Previous_Value__c = null;
    rec.Previous_Expires_At__c = null;
    upsert as system rec;
  }

  /**
   * @description Makes a new Standard Webhooks secret. The old value stays
   * valid until the grace time ends.
   * @param name The secret name.
   * @param graceHours Hours to keep the old value.
   * @return The new value, whsec_ and 32 random bytes in base64.
   */
  public static String rotate(String name, Integer graceHours) {
    Hook_Secret__c rec = load(name);
    String fresh = generate();
    if (String.isNotBlank(rec.Value__c)) {
      rec.Previous_Value__c = rec.Value__c;
      rec.Previous_Expires_At__c = HookClock.now()
        .addHours(Math.max(0, graceHours == null ? 0 : graceHours));
    }
    rec.Value__c = fresh;
    upsert as system rec;
    return fresh;
  }

  /**
   * @description Makes a random Standard Webhooks secret.
   * @return whsec_ and 32 random bytes in base64.
   */
  public static String generate() {
    return 'whsec_' + EncodingUtil.base64Encode(Crypto.generateAesKey(256));
  }

  private static Hook_Secret__c load(String name) {
    if (String.isBlank(name) || name.trim().length() > MAX_NAME) {
      throw new HookException(
        'A secret name must have 1 to ' + MAX_NAME + ' characters.'
      );
    }
    String key = name.trim();
    Hook_Secret__c rec = Hook_Secret__c.getInstance(key);
    return rec != null && rec.Id != null ? rec : new Hook_Secret__c(Name = key);
  }
}
