/**
 * @description Reads Hook_Endpoint__mdt. Tests add records to overrides.
 */
public inherited sharing class HookEndpoints {
  /** @description Test records by name. */
  @TestVisible
  private static Map<String, Hook_Endpoint__mdt> overrides = new Map<String, Hook_Endpoint__mdt>();
  private static Map<String, Hook_Endpoint__mdt> cache = new Map<String, Hook_Endpoint__mdt>();

  /**
   * @description Gives an endpoint by name.
   * @param name The record name.
   * @return The record, or null for a bad or unknown name.
   */
  public static Hook_Endpoint__mdt get(String name) {
    if (
      String.isBlank(name) ||
      !Pattern.matches('[A-Za-z][A-Za-z0-9_]{0,39}', name)
    ) {
      return null;
    }
    if (overrides.containsKey(name)) {
      return overrides.get(name);
    }
    if (Test.isRunningTest() && !overrides.isEmpty()) {
      return null;
    }
    if (!cache.containsKey(name)) {
      cache.put(name, query(name));
    }
    return cache.get(name);
  }

  // SOQL, not getInstance(): getInstance() gives only the first 255
  // characters of a long text field such as Handler_Config__c.
  private static Hook_Endpoint__mdt query(String name) {
    List<Hook_Endpoint__mdt> rows = [
      SELECT
        DeveloperName,
        Active__c,
        Scheme__c,
        Verifier_Class__c,
        Secret_Names__c,
        Handler_Class__c,
        Handler_Config__c,
        Tolerance_Seconds__c,
        Signature_Header__c,
        Signature_Prefix__c,
        Signature_Encoding__c,
        Event_Id_Header__c,
        Event_Id_Path__c,
        Event_Type_Header__c,
        Event_Type_Path__c,
        Max_Attempts__c
      FROM Hook_Endpoint__mdt
      WHERE DeveloperName = :name
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0];
  }
}
