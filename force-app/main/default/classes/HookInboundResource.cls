/**
 * @description The inbound REST endpoint: /services/apexrest/hook/{name}.
 * Give the Site guest user access with the permission set Hook_Guest.
 */
@RestResource(urlMapping='/hook/*')
global with sharing class HookInboundResource {
  /**
   * @description Receives a webhook.
   */
  @HttpPost
  global static void doPost() {
    respond('POST');
  }

  /**
   * @description Answers a GET handshake. With no handshake it returns 405.
   */
  @HttpGet
  global static void doGet() {
    respond('GET');
  }

  private static void respond(String method) {
    HookResponse res = HookInbound.receive(
      HookRequest.fromRest(RestContext.request, method)
    );
    RestResponse out = RestContext.response;
    out.statusCode = res.statusCode;
    out.addHeader('Content-Type', res.contentType);
    out.responseBody = Blob.valueOf(res.body == null ? '' : res.body);
  }
}
