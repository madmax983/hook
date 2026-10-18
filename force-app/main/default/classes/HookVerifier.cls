/**
 * @description Checks that an inbound request is authentic.
 * Set Hook_Endpoint__mdt.Verifier_Class__c to use a custom class.
 */
global interface HookVerifier {
  /**
   * @description Verifies the request.
   * @param request The request.
   * @param secrets The active secrets of the endpoint.
   * @return The result.
   */
  HookVerification verify(HookRequest request, List<String> secrets);
}
