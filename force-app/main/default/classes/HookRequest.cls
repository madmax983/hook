/**
 * @description One inbound request. Header names are lower case, so a lookup
 * ignores case.
 */
global inherited sharing class HookRequest {
  /** @description The HTTP method, for example POST. */
  global String method { get; private set; }
  /** @description The endpoint name: the last path segment. */
  global String endpoint { get; private set; }
  /** @description The raw body bytes. Verifiers sign these bytes. */
  global Blob bodyBlob { get; private set; }
  /** @description The body as UTF-8 text. */
  global String body { get; private set; }
  /** @description The caller IP address. */
  global String remoteAddress { get; private set; }

  private final Map<String, String> headers = new Map<String, String>();
  private final Map<String, String> params;

  /**
   * @description Makes a request.
   * @param method The HTTP method.
   * @param endpoint The endpoint name.
   * @param bodyBlob The raw body, or null.
   * @param headers The headers, with names in any case.
   * @param params The query parameters.
   * @param remoteAddress The caller IP address.
   */
  @SuppressWarnings('PMD.ExcessiveParameterList')
  public HookRequest(
    String method,
    String endpoint,
    Blob bodyBlob,
    Map<String, String> headers,
    Map<String, String> params,
    String remoteAddress
  ) {
    this.method = method == null ? null : method.toUpperCase();
    this.endpoint = endpoint;
    this.bodyBlob = bodyBlob == null ? Blob.valueOf('') : bodyBlob;
    this.params = params == null ? new Map<String, String>() : params;
    this.remoteAddress = remoteAddress;
    if (headers != null) {
      for (String key : headers.keySet()) {
        this.headers.put(key.toLowerCase(), headers.get(key));
      }
    }
  }

  /**
   * @description Decodes the body as UTF-8.
   * @return True when the body is valid UTF-8.
   */
  public Boolean decodeBody() {
    try {
      body = bodyBlob.toString();
      return true;
    } catch (Exception e) {
      return false;
    }
  }

  /**
   * @description Reads a header. The name ignores case.
   * @param name The header name.
   * @return The value, or null.
   */
  global String header(String name) {
    return name == null ? null : headers.get(name.toLowerCase());
  }

  /**
   * @description Reads a query parameter.
   * @param name The parameter name.
   * @return The value, or null.
   */
  global String param(String name) {
    return params.get(name);
  }

  /**
   * @description Gives the headers with lower-case names.
   * @return A copy of the headers.
   */
  public Map<String, String> headers() {
    return headers.clone();
  }

  /**
   * @description Gives the endpoint name from a REST request URI.
   * @param uri The URI after /services/apexrest, for example /hook/stripe.
   * @return The last path segment, or null.
   */
  public static String endpointFromUri(String uri) {
    if (uri == null) {
      return null;
    }
    String path = uri.substringBefore('?').removeEnd('/');
    String last = path.substringAfterLast('/');
    return String.isBlank(last) || last == 'hook' ? null : last;
  }

  /**
   * @description Makes a request from the REST context.
   * @param rest The REST request.
   * @param method The HTTP method.
   * @return The request.
   */
  public static HookRequest fromRest(RestRequest rest, String method) {
    return new HookRequest(
      method,
      endpointFromUri(rest.requestURI),
      rest.requestBody,
      rest.headers,
      rest.params,
      rest.remoteAddress
    );
  }
}
