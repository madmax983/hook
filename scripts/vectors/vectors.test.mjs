// Checks the static resource HookTestVectors against node:crypto and published values.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { FILE, build, render } from "./generate.mjs";

test("the static resource is equal to the generated vectors", () => {
  assert.equal(readFileSync(FILE, "utf8"), render(), "Run npm run vectors");
});

test("the Standard Webhooks vector is equal to the published value", () => {
  // From the Standard Webhooks specification test suite.
  assert.equal(build().standardWebhooks[0].signature, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=");
});

test("the GitHub vector is equal to the published value", () => {
  // From the GitHub docs, "Validating webhook deliveries".
  assert.equal(
    build().github.helloWorldHeader,
    "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17",
  );
});

test("the unicode body has multi-byte characters", () => {
  const { body } = build().standardWebhooks[1];
  assert.ok(Buffer.byteLength(body, "utf8") > body.length);
});
