// Checks the security settings in the metadata (AC-SEC-2, AC-SEC-4, AC-SEC-6).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const read = (path) => readFileSync(join(ROOT, "force-app/main/default", path), "utf8");
const all = (xml, tag) => [...xml.matchAll(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`, "g"))].map((m) => m[1]);
const value = (xml, tag) => (xml.match(new RegExp(`<${tag}>([^<]*)</${tag}>`)) || [])[1];

test("Hook_Secret__c is a protected list Custom Setting", () => {
  const xml = read("objects/Hook_Secret__c/Hook_Secret__c.object-meta.xml");
  assert.equal(value(xml, "customSettingsType"), "List");
  assert.equal(value(xml, "visibility"), "Protected");
});

test("Hook_Guest gives only the REST class and the platform event create", () => {
  const xml = read("permissionsets/Hook_Guest.permissionset-meta.xml");
  assert.deepEqual(all(xml, "classAccesses").map((c) => value(c, "apexClass")), ["HookInboundResource"]);
  const objects = all(xml, "objectPermissions");
  assert.equal(objects.length, 1);
  assert.equal(value(objects[0], "object"), "Hook_Inbound__e");
  assert.equal(value(objects[0], "allowCreate"), "true");
  for (const tag of ["allowEdit", "allowDelete", "modifyAllRecords", "viewAllRecords"]) {
    assert.equal(value(objects[0], tag), "false", tag);
  }
  assert.equal(all(xml, "fieldPermissions").length, 0);
  assert.equal(all(xml, "userPermissions").length, 0);
});

test("the subscription endpoint must be https or a Named Credential", () => {
  const xml = read("objects/Hook_Subscription__c/validationRules/Endpoint_Must_Be_Secure.validationRule-meta.xml");
  assert.equal(value(xml, "active"), "true");
  const formula = value(xml, "errorConditionFormula");
  assert.match(formula, /BEGINS\(Endpoint__c, "https:\/\/"\)/);
  assert.match(formula, /BEGINS\(Endpoint__c, "callout:"\)/);
});

test("the inbound platform event publishes after commit", () => {
  const xml = read("objects/Hook_Inbound__e/Hook_Inbound__e.object-meta.xml");
  assert.equal(value(xml, "publishBehavior"), "PublishAfterCommit");
});

test("the dedup keys are unique and case-sensitive", () => {
  for (const obj of ["Hook_Delivery__c", "Hook_Inbound_Event__c"]) {
    const xml = read(`objects/${obj}/fields/Dedup_Key__c.field-meta.xml`);
    assert.equal(value(xml, "unique"), "true", obj);
    assert.equal(value(xml, "caseSensitive"), "true", obj);
  }
});
