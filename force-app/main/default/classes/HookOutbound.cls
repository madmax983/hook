/**
 * @description The outbox (ADR 0002). Hook.send inserts one Hook_Delivery__c
 * for each matching subscription, then calls the channel of each row. It must
 * see every subscription, so it runs without sharing.
 */
public without sharing class HookOutbound {
  /** @description Largest body. It is the Payload__c length. */
  public static final Integer MAX_PAYLOAD_CHARS = 131072;
  private static final Integer MAX_KEY = 255;

  /**
   * @description Sends events.
   * @param events The events.
   * @return The event Ids, in the order of the events.
   * @throws HookException For a blank type, a large payload or a failed insert.
   */
  public static List<String> send(List<HookEvent> events) {
    List<String> ids = new List<String>();
    List<String> bodies = new List<String>();
    for (HookEvent e : events) {
      if (e == null || String.isBlank(e.eventType)) {
        throw new HookException('An event needs a type.');
      }
      String id = String.isBlank(e.eventId) ? newEventId() : e.eventId.trim();
      String body = envelope(id, e.eventType.trim(), e.payload);
      if (body.length() > MAX_PAYLOAD_CHARS) {
        throw new HookException(
          'The payload is larger than ' + MAX_PAYLOAD_CHARS + ' characters.'
        );
      }
      ids.add(id);
      bodies.add(body);
    }
    List<Hook_Subscription__c> subs = [
      SELECT Id, Event_Types__c, Channel__c
      FROM Hook_Subscription__c
      WHERE Active__c = TRUE
      WITH SYSTEM_MODE
    ];
    List<Hook_Delivery__c> rows = new List<Hook_Delivery__c>();
    for (Integer i = 0; i < events.size(); i++) {
      String type = events[i].eventType.trim();
      for (Hook_Subscription__c sub : subs) {
        if (matches(sub.Event_Types__c, type)) {
          rows.add(row(sub, ids[i], type, bodies[i]));
        }
      }
    }
    if (rows.isEmpty()) {
      return ids;
    }
    List<Hook_Delivery__c> inserted = new List<Hook_Delivery__c>();
    Database.SaveResult[] results = Database.insert(
      rows,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        inserted.add(rows[i]);
      } else if (!HookInbound.isDuplicate(results[i])) {
        throw new HookException(
          'Hook could not store a delivery: ' +
          results[i].getErrors()[0].getMessage()
        );
      }
    }
    dispatch(inserted);
    return ids;
  }

  /**
   * @description Sets the rows to Pending with no attempts, adds 1 to the
   * generation, and dispatches them again.
   * @param ids The Hook_Delivery__c Ids.
   */
  public static void redeliver(Set<Id> ids) {
    List<Hook_Delivery__c> rows = [
      SELECT Id, Channel__c, Generation__c
      FROM Hook_Delivery__c
      WHERE Id IN :ids
      WITH SYSTEM_MODE
    ];
    for (Hook_Delivery__c d : rows) {
      d.Status__c = 'Pending';
      d.Attempts__c = 0;
      d.Generation__c = (d.Generation__c == null ? 0 : d.Generation__c) + 1;
      d.Next_Attempt_At__c = null;
      d.Claim_Token__c = null;
      d.Lease_Until__c = null;
      d.Last_Error__c = null;
    }
    update as system rows;
    dispatch(rows);
  }

  /**
   * @description Tells if an event type matches a subscription filter.
   * @param filter Types separated by commas, semicolons or spaces. * is all. A.* is a prefix.
   * @param type The event type.
   * @return True for a match. The compare ignores case.
   */
  public static Boolean matches(String filter, String type) {
    if (String.isBlank(filter)) {
      return false;
    }
    for (String token : filter.trim().split('[,;\\s]+')) {
      if (token == '*' || token.equalsIgnoreCase(type)) {
        return true;
      }
      if (
        token.endsWith('.*') &&
        type.toLowerCase().startsWith(token.removeEnd('*').toLowerCase())
      ) {
        return true;
      }
    }
    return false;
  }

  /**
   * @description Calls the channel of each row. A channel that cannot be made fails its rows.
   * @param rows The rows. Each has Channel__c.
   */
  public static void dispatch(List<Hook_Delivery__c> rows) {
    Map<String, List<Id>> byChannel = new Map<String, List<Id>>();
    for (Hook_Delivery__c d : rows) {
      String name = String.isBlank(d.Channel__c)
        ? HookConfig.defaultChannel()
        : d.Channel__c;
      if (!byChannel.containsKey(name)) {
        byChannel.put(name, new List<Id>());
      }
      byChannel.get(name).add(d.Id);
    }
    List<Hook_Delivery__c> failed = new List<Hook_Delivery__c>();
    for (String name : byChannel.keySet()) {
      HookChannel channel;
      try {
        Object made = HookTypes.make(name, 'HookChannel');
        if (!(made instanceof HookChannel)) {
          throw HookTypes.wrongType(name, 'HookChannel');
        }
        channel = (HookChannel) made;
      } catch (HookException e) {
        for (Id id : byChannel.get(name)) {
          failed.add(
            new Hook_Delivery__c(
              Id = id,
              Status__c = 'Failed',
              Last_Error__c = e.getMessage()
            )
          );
        }
        continue;
      }
      channel.dispatch(byChannel.get(name));
    }
    if (!failed.isEmpty()) {
      update as system failed;
    }
  }

  private static Hook_Delivery__c row(
    Hook_Subscription__c sub,
    String eventId,
    String type,
    String body
  ) {
    String dedup = sub.Id + ':' + eventId;
    if (dedup.length() > MAX_KEY) {
      dedup =
        sub.Id +
        ':' +
        EncodingUtil.convertToHex(
          Crypto.generateDigest('SHA-256', Blob.valueOf(eventId))
        );
    }
    return new Hook_Delivery__c(
      Subscription__c = sub.Id,
      Event_Id__c = eventId.left(MAX_KEY),
      Event_Type__c = type.left(MAX_KEY),
      Dedup_Key__c = dedup,
      Payload__c = body,
      Status__c = 'Pending',
      Attempts__c = 0,
      Generation__c = 0,
      Channel__c = String.isBlank(sub.Channel__c)
        ? HookConfig.defaultChannel()
        : sub.Channel__c.trim()
    );
  }

  private static String newEventId() {
    return 'msg_' + EncodingUtil.convertToHex(Crypto.generateAesKey(128));
  }

  /**
   * @description Builds the Standard Webhooks body: id, type, timestamp and data.
   * @param id The event Id.
   * @param type The event type.
   * @param payload The data.
   * @return The JSON body.
   */
  public static String envelope(String id, String type, Object payload) {
    JSONGenerator gen = JSON.createGenerator(false);
    gen.writeStartObject();
    gen.writeStringField('id', id);
    gen.writeStringField('type', type);
    gen.writeStringField(
      'timestamp',
      HookClock.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'')
    );
    gen.writeFieldName('data');
    if (payload == null) {
      gen.writeNull();
    } else {
      gen.writeObject(payload);
    }
    gen.writeEndObject();
    return gen.getAsString();
  }
}
