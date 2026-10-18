/**
 * @description The response to an inbound request.
 */
global inherited sharing class HookResponse {
  /** @description The HTTP status code. */
  global Integer statusCode { get; private set; }
  /** @description The body. */
  global String body { get; private set; }
  /** @description The Content-Type. */
  global String contentType { get; private set; }

  /**
   * @description Makes a response.
   * @param statusCode The HTTP status code.
   * @param body The body.
   * @param contentType The Content-Type.
   */
  global HookResponse(Integer statusCode, String body, String contentType) {
    this.statusCode = statusCode;
    this.body = body;
    this.contentType = contentType;
  }

  /**
   * @description Makes a JSON response.
   * @param statusCode The HTTP status code.
   * @param values The JSON fields.
   * @return The response.
   */
  public static HookResponse ofJson(
    Integer statusCode,
    Map<String, Object> values
  ) {
    return new HookResponse(
      statusCode,
      JSON.serialize(values),
      'application/json'
    );
  }
}
