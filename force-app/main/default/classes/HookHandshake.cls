/**
 * @description Answers a provider handshake, for example a Slack
 * url_verification or a GET challenge. A verifier or a handler can implement it.
 */
global interface HookHandshake {
  /**
   * @description Answers a handshake. For a POST, Hook calls it after a valid verification.
   * @param request The request.
   * @param secrets The active secrets of the endpoint.
   * @return The response, or null when the request is not a handshake.
   */
  HookResponse respond(HookRequest request, List<String> secrets);
}
