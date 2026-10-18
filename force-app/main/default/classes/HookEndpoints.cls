/**
 * @description Reads Hook_Endpoint__mdt. Tests add records to overrides.
 */
public inherited sharing class HookEndpoints {
  /** @description Test records by name. */
  @TestVisible
  private static Map<String, Hook_Endpoint__mdt> overrides = new Map<String, Hook_Endpoint__mdt>();

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
    return Test.isRunningTest() && !overrides.isEmpty()
      ? null
      : Hook_Endpoint__mdt.getInstance(name);
  }
}
