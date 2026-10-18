/**
 * @description One delivery attempt: prepare (SOQL), send (one callout, no
 * DML), record (DML). Channels use it. It must see every row, so it runs
 * without sharing.
 */
global without sharing class HookDelivery {
  /** @description Largest stored response body. */
  public static final Integer MAX_RESPONSE = 2000;
  private static final Integer MAX_TEXT = 32768;
  /** @description Lease that a job needs: 120 s of callouts and a margin. */
  private static final Integer LEASE_FLOOR_SECONDS = 130;

  /** @description Sends the request. Tests can replace it. */
  @TestVisible
  private static HookTransport transport = new HttpTransport();

  /**
   * @description The production transport. It makes a real callout.
   */
  public class HttpTransport implements HookTransport {
    /**
     * @description Sends the request with Http.send.
     * @param req The request.
     * @return The response.
     */
    public HttpResponse send(HttpRequest req) {
      return new Http().send(req);
    }
  }

  private HookDelivery() {
    return;
  }

  /**
   * @description Reads a delivery and its subscription.
   * @param deliveryId The Hook_Delivery__c Id.
   * @return The attempt, or null when the row does not exist.
   */
  global static Attempt prepare(Id deliveryId) {
    List<Attempt> found = wrap(
      [
        SELECT
          Id,
          Status__c,
          Attempts__c,
          Payload__c,
          Event_Id__c,
          Claim_Token__c,
          Generation__c,
          Subscription__c,
          Subscription__r.Endpoint__c,
          Subscription__r.Secret_Name__c,
          Subscription__r.Max_Attempts__c,
          Subscription__r.Active__c,
          Subscription__r.Consecutive_Failures__c
        FROM Hook_Delivery__c
        WHERE Id = :deliveryId
        WITH SYSTEM_MODE
      ]
    );
    return found.isEmpty() ? null : found[0];
  }

  /**
   * @description Reads the rows that a claim token owns.
   * @param token The claim token.
   * @param max The most rows.
   * @return The attempts.
   */
  public static List<Attempt> claimed(String token, Integer max) {
    // A row with less lease than one job of callouts stays for the next claim.
    Datetime leaseFloor = HookClock.now().addSeconds(LEASE_FLOOR_SECONDS);
    return wrap(
      [
        SELECT
          Id,
          Status__c,
          Attempts__c,
          Payload__c,
          Event_Id__c,
          Claim_Token__c,
          Generation__c,
          Subscription__c,
          Subscription__r.Endpoint__c,
          Subscription__r.Secret_Name__c,
          Subscription__r.Max_Attempts__c,
          Subscription__r.Active__c,
          Subscription__r.Consecutive_Failures__c
        FROM Hook_Delivery__c
        WHERE
          Claim_Token__c = :token
          AND Status__c = 'In_Flight'
          AND Lease_Until__c > :leaseFloor
        WITH SYSTEM_MODE
        LIMIT :max
      ]
    );
  }

  private static List<Attempt> wrap(List<Hook_Delivery__c> rows) {
    List<Attempt> attempts = new List<Attempt>();
    for (Hook_Delivery__c row : rows) {
      attempts.add(new Attempt(row));
    }
    return attempts;
  }

  /**
   * @description Writes the result of each sent attempt and updates the
   * failure count of each subscription. It reads the rows and the
   * subscriptions again with a lock. It skips a row that another job or a
   * redelivery took after the read, and it changes Active__c only to disable.
   * @param attempts The attempts. An attempt with no outcome is skipped.
   */
  public static void saveAll(List<Attempt> attempts) {
    Set<Id> rowIds = new Set<Id>();
    Set<Id> subIds = new Set<Id>();
    for (Attempt a : attempts) {
      if (a.outcome != null) {
        rowIds.add(a.deliveryId);
        subIds.add(a.row.Subscription__c);
      }
    }
    if (rowIds.isEmpty()) {
      return;
    }
    Map<Id, Hook_Delivery__c> fresh = new Map<Id, Hook_Delivery__c>(
      [
        SELECT Id, Claim_Token__c, Generation__c
        FROM Hook_Delivery__c
        WHERE Id IN :rowIds
        WITH SYSTEM_MODE
        FOR UPDATE
      ]
    );
    Map<Id, Hook_Subscription__c> subs = new Map<Id, Hook_Subscription__c>(
      [
        SELECT Id, Active__c, Consecutive_Failures__c, Disabled_Reason__c
        FROM Hook_Subscription__c
        WHERE Id IN :subIds
        WITH SYSTEM_MODE
        FOR UPDATE
      ]
    );
    Datetime now = HookClock.now();
    Integer disableAfter = HookConfig.disableAfterFailures();
    List<Hook_Delivery__c> rows = new List<Hook_Delivery__c>();
    Map<Id, Hook_Subscription__c> changed = new Map<Id, Hook_Subscription__c>();
    for (Attempt a : attempts) {
      Hook_Subscription__c sub = subs.get(a.row.Subscription__c);
      if (
        a.outcome == null ||
        sub == null ||
        !a.stillOwns(fresh.get(a.deliveryId))
      ) {
        continue;
      }
      if (sub.Consecutive_Failures__c == null) {
        sub.Consecutive_Failures__c = 0;
      }
      rows.add(a.apply(now, sub, disableAfter));
      changed.put(sub.Id, sub);
    }
    update as system rows;
    update as system changed.values();
  }

  /**
   * @description Classifies a response.
   * @param res The response.
   * @return The outcome.
   */
  public static Outcome outcomeOf(HttpResponse res) {
    Integer code = res.getStatusCode();
    String body = res.getBody();
    Outcome o;
    if (code >= 200 && code < 300) {
      o = new Outcome('DELIVERED', code, null);
    } else if (code == 410) {
      o = new Outcome('GONE', code, 'HTTP 410');
    } else {
      Integer after = (code == 429 ||
        code == 503)
        ? HookRetryAfter.seconds(res.getHeader('Retry-After'))
        : null;
      o = retryOutcome(code, after, 'HTTP ' + code);
    }
    o.responseBody = body == null ? null : body.left(MAX_RESPONSE);
    return o;
  }

  /**
   * @description Makes a RETRY outcome.
   * @param code The HTTP status, or null.
   * @param after The Retry-After seconds, or null.
   * @param error The error.
   * @return The outcome.
   */
  public static Outcome retryOutcome(
    Integer code,
    Integer after,
    String error
  ) {
    Outcome o = new Outcome('RETRY', code, error);
    o.retryAfterSeconds = after;
    return o;
  }

  /**
   * @description Makes a CONFIG outcome: a setup error that a retry cannot fix.
   * @param error The error.
   * @return The outcome.
   */
  public static Outcome configOutcome(String error) {
    return new Outcome('CONFIG', null, error);
  }

  /**
   * @description One attempt on one delivery.
   */
  global class Attempt {
    /** @description The row, with its subscription fields. */
    public Hook_Delivery__c row;
    /** @description The outcome after send(). */
    public Outcome outcome;
    /** @description The next attempt time that record() sets. */
    public Datetime nextAttemptAt;

    /** @description The Hook_Delivery__c Id. */
    global Id deliveryId { get; private set; }
    /** @description Attempts made before this one. */
    global Integer attempts { get; private set; }
    /** @description The subscription value, else the org default. */
    global Integer maxAttempts { get; private set; }

    /**
     * @description Makes an attempt for a row.
     * @param row The row, with its subscription fields.
     */
    public Attempt(Hook_Delivery__c row) {
      this.row = row;
      this.deliveryId = row.Id;
      this.attempts = row.Attempts__c == null ? 0 : row.Attempts__c.intValue();
      Decimal subMax = row.Subscription__r.Max_Attempts__c;
      this.maxAttempts = subMax == null
        ? HookConfig.maxAttempts()
        : Math.max(1, subMax.intValue());
    }

    /**
     * @description Tells if the row is already delivered.
     * @return True for Delivered.
     */
    global Boolean isDelivered() {
      return row.Status__c == 'Delivered';
    }

    /**
     * @description Sends the signed request. One callout and no DML.
     * @return The outcome.
     */
    global Outcome send() {
      if (row.Subscription__r.Active__c != true) {
        outcome = new Outcome(
          'PAUSED',
          null,
          'The subscription is not active.'
        );
        return outcome;
      }
      List<String> secrets = HookSecrets.valuesFor(
        row.Subscription__r.Secret_Name__c
      );
      if (secrets.isEmpty()) {
        outcome = configOutcome(
          'No secret is set for the subscription. Set Hook_Secret__c "' +
            row.Subscription__r.Secret_Name__c +
            '".'
        );
        return outcome;
      }
      try {
        outcome = outcomeOf(transport.send(request(secrets)));
      } catch (CalloutException e) {
        outcome = retryOutcome(
          null,
          null,
          'CalloutException: ' + e.getMessage()
        );
      } catch (Exception e) {
        // For example, a secret that is not valid base64. A retry cannot fix it.
        outcome = configOutcome(
          'Hook could not send: ' + e.getTypeName() + ': ' + e.getMessage()
        );
      }
      return outcome;
    }

    private HttpRequest request(List<String> secrets) {
      Long ts = HookClock.nowSeconds();
      HttpRequest req = new HttpRequest();
      req.setEndpoint(row.Subscription__r.Endpoint__c);
      req.setMethod('POST');
      req.setTimeout(HookConfig.timeoutMs());
      req.setHeader('Content-Type', 'application/json');
      req.setHeader('User-Agent', 'Hook/1.0');
      req.setHeader('webhook-id', row.Event_Id__c);
      req.setHeader('webhook-timestamp', String.valueOf(ts));
      req.setHeader(
        'webhook-signature',
        HookSigner.signatureHeader(secrets, row.Event_Id__c, ts, row.Payload__c)
      );
      req.setBody(row.Payload__c);
      return req;
    }

    /**
     * @description Tells if this attempt still owns the row: the claim token
     * and the generation did not change after the read.
     * @param current The row as it is now, or null when it is deleted.
     * @return True when the attempt can write the row.
     */
    public Boolean stillOwns(Hook_Delivery__c current) {
      return current != null &&
        same(current.Claim_Token__c, row.Claim_Token__c) &&
        current.Generation__c == row.Generation__c;
    }

    private Boolean same(String a, String b) {
      return a == null ? b == null : a.equals(b);
    }

    /**
     * @description Writes the outcome. Delivered sets Delivered. Else a
     * non-null time sets Retrying, and null sets Failed.
     * @param nextAttemptAt The next attempt time, or null for no retry.
     */
    global void record(Datetime nextAttemptAt) {
      this.nextAttemptAt = nextAttemptAt;
      saveAll(new List<Attempt>{ this });
    }

    /**
     * @description Applies the outcome to the row and the subscription.
     * @param now The time.
     * @param sub The subscription to change.
     * @param disableAfter Failed attempts in a row that disable it. 0 is never.
     */
    public Hook_Delivery__c apply(
      Datetime now,
      Hook_Subscription__c sub,
      Integer disableAfter
    ) {
      Hook_Delivery__c out = new Hook_Delivery__c(
        Id = deliveryId,
        Claim_Token__c = null,
        Lease_Until__c = null,
        Next_Attempt_At__c = null,
        Last_Status_Code__c = outcome.statusCode,
        Last_Error__c = outcome.error == null
          ? null
          : outcome.error.left(MAX_TEXT),
        Last_Response__c = outcome.responseBody
      );
      if (outcome.kind == 'PAUSED') {
        // Not an attempt. The row waits until the subscription is active again.
        out.Status__c = 'Pending';
        row.Status__c = out.Status__c;
        return out;
      }
      out.Attempts__c = attempts + 1;
      out.Last_Attempt_At__c = now;
      switch on outcome.kind {
        when 'DELIVERED' {
          out.Status__c = 'Delivered';
          out.Delivered_At__c = now;
          sub.Consecutive_Failures__c = 0;
        }
        when 'GONE' {
          out.Status__c = 'Failed';
          sub.Consecutive_Failures__c += 1;
          disable(sub, 'The endpoint returned HTTP 410 Gone.');
        }
        when 'RETRY' {
          sub.Consecutive_Failures__c += 1;
          out.Status__c = nextAttemptAt == null ? 'Failed' : 'Retrying';
          out.Next_Attempt_At__c = nextAttemptAt;
        }
        when else {
          out.Status__c = 'Failed';
        }
      }
      if (disableAfter > 0 && sub.Consecutive_Failures__c >= disableAfter) {
        disable(
          sub,
          'Disabled after ' +
            sub.Consecutive_Failures__c.intValue() +
            ' failed attempts in a row.'
        );
      }
      row.Status__c = out.Status__c;
      return out;
    }

    private void disable(Hook_Subscription__c sub, String reason) {
      if (sub.Active__c != false) {
        sub.Active__c = false;
        sub.Disabled_Reason__c = reason;
      }
    }
  }

  /**
   * @description The result of one send.
   */
  global class Outcome {
    /** @description DELIVERED, RETRY, GONE, CONFIG or PAUSED (the subscription is not active). */
    global String kind { get; private set; }
    /** @description The HTTP status, or null. */
    global Integer statusCode { get; private set; }
    /** @description The Retry-After of a 429 or 503, in seconds, or null. */
    global Integer retryAfterSeconds { get; public set; }
    /** @description The error, or null. */
    global String error { get; private set; }
    /** @description The first MAX_RESPONSE characters of the response body. */
    public String responseBody;

    /**
     * @description Makes an outcome.
     * @param kind The kind.
     * @param statusCode The HTTP status, or null.
     * @param error The error, or null.
     */
    public Outcome(String kind, Integer statusCode, String error) {
      this.kind = kind;
      this.statusCode = statusCode;
      this.error = error;
    }

    /**
     * @description Tells if the endpoint accepted the event.
     * @return True for DELIVERED.
     */
    global Boolean isDelivered() {
      return kind == 'DELIVERED';
    }

    /**
     * @description Tells if another attempt can succeed.
     * @return True for RETRY.
     */
    global Boolean isRetryable() {
      return kind == 'RETRY';
    }
  }
}
