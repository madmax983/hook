// Checks that the global declarations in force-app are equal to docs/api.md.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { manifest, surfaceOf, surfaceOfFolder } from "./surface.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

test("the parser reads types, methods, properties, fields and interfaces", () => {
  const src = `
    /** A class. */
    global with sharing class A implements B {
      global static String send(String t, Map<String, Object> p) { return null; }
      global A(Integer x) {}
      public void hidden() {}
      global String name { get; private set; }
      global Integer both { get; set; }
      @InvocableVariable(label='x' required=true)
      global String v;
      global static final Integer MAX = 5;
      // global void commented();
      global class Inner { global List<Id> ids() { return null; } }
      private class Hidden { global void no() {} }
    }
    global interface I { void handle(A a); }
    public class P { global void notGlobal() {} }`;
  assert.deepEqual(surfaceOf(src), [
    "global class A implements B",
    "static A.send(String, Map<String, Object>): String",
    "new A(Integer)",
    "A.name: String { get }",
    "A.both: Integer { get; set }",
    "@InvocableVariable(required=true) A.v: String",
    "static final A.MAX: Integer",
    "global class A.Inner",
    "A.Inner.ids(): List<Id>",
    "global interface I",
    "I.handle(A): void",
  ]);
});

test("the global surface is equal to docs/api.md", () => {
  const expected = manifest(readFileSync(join(ROOT, "docs/api.md"), "utf8"));
  const actual = surfaceOfFolder(join(ROOT, "force-app"));
  assert.equal(new Set(expected).size, expected.length, "The manifest has a duplicate line");
  const missing = expected.filter((l) => !actual.includes(l));
  const extra = actual.filter((l) => !expected.includes(l));
  assert.deepEqual({ missing, extra }, { missing: [], extra: [] });
});

test("the Revenant adapter has no global declaration", () => {
  assert.deepEqual(surfaceOfFolder(join(ROOT, "revenant-adapter")), []);
});
