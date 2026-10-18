/**
 * @description Sends one HTTP request. Tests can replace the transport.
 */
public interface HookTransport {
  /**
   * @description Sends the request.
   * @param req The request.
   * @return The response.
   */
  HttpResponse send(HttpRequest req);
}
