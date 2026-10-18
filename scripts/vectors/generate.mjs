#!/usr/bin/env node
// Builds the signature test vectors with node:crypto.
// The Apex tests read the same file as the static resource HookTestVectors.
// Run: npm run vectors
import { createHmac } from "node:crypto";
import { writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
export const FILE = join(
  ROOT,
  "force-app/main/default/staticresources/HookTestVectors.json",
);

const hmac = (key, data, encoding) => createHmac("sha256", key).update(data, "utf8").digest(encoding);

/** Standard Webhooks: key is base64 after "whsec_", data is "id.timestamp.body". */
export function standardSignature(secret, id, timestamp, body) {
  const key = Buffer.from(secret.replace(/^whsec_/, ""), "base64");
  return `v1,${hmac(key, `${id}.${timestamp}.${body}`, "base64")}`;
}

const STANDARD_SECRET = `whsec_${Buffer.from("hook-standard-webhooks-test-key!").toString("base64")}`;
const STRIPE_SECRET = "whsec_stripe_test_secret";
const GITHUB_SECRET = "It's a Secret to Everybody";
const SLACK_SECRET = "8f742231b10e8888abcd99yyyzzz85a5";
const SHOPIFY_SECRET = "shpss_hook_test_secret";

const stripeBody = '{"id":"evt_1","type":"payment_intent.succeeded","data":{"object":{"id":"pi_1"}}}';
const githubBody = '{"action":"opened","number":7}';
const slackEvent = '{"type":"event_callback","event_id":"Ev01","event":{"type":"app_mention","text":"hi"}}';
const slackChallenge = '{"type":"url_verification","token":"t","challenge":"3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P"}';
const shopifyBody = '{"id":820982911946154500,"email":"jon@example.com"}';
const unicodeBody = '{"name":"Zoë","note":"café ☕"}';

export function build() {
  return {
    standardWebhooks: [
      {
        name: "spec",
        secret: "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw",
        id: "msg_p5jXN8AQM9LWM0D4loKWxJek",
        timestamp: 1614265330,
        body: '{"test": 2432232314}',
        signature: standardSignature(
          "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw",
          "msg_p5jXN8AQM9LWM0D4loKWxJek",
          1614265330,
          '{"test": 2432232314}',
        ),
      },
      {
        name: "unicode",
        secret: STANDARD_SECRET,
        id: "msg_unicode",
        timestamp: 1700000000,
        body: unicodeBody,
        signature: standardSignature(STANDARD_SECRET, "msg_unicode", 1700000000, unicodeBody),
      },
    ],
    stripe: {
      secret: STRIPE_SECRET,
      timestamp: 1700000000,
      body: stripeBody,
      header: `t=1700000000,v1=${hmac(STRIPE_SECRET, `1700000000.${stripeBody}`, "hex")},v0=00`,
    },
    github: {
      secret: GITHUB_SECRET,
      body: githubBody,
      header: `sha256=${hmac(GITHUB_SECRET, githubBody, "hex")}`,
      helloWorldHeader: `sha256=${hmac(GITHUB_SECRET, "Hello, World!", "hex")}`,
    },
    slack: {
      secret: SLACK_SECRET,
      timestamp: 1531420618,
      eventBody: slackEvent,
      eventSignature: `v0=${hmac(SLACK_SECRET, `v0:1531420618:${slackEvent}`, "hex")}`,
      challengeBody: slackChallenge,
      challengeSignature: `v0=${hmac(SLACK_SECRET, `v0:1531420618:${slackChallenge}`, "hex")}`,
    },
    shopify: {
      secret: SHOPIFY_SECRET,
      body: shopifyBody,
      header: hmac(SHOPIFY_SECRET, shopifyBody, "base64"),
    },
    hmac: {
      secret: "plain-secret",
      body: unicodeBody,
      hex: hmac("plain-secret", unicodeBody, "hex"),
      base64: hmac("plain-secret", unicodeBody, "base64"),
    },
  };
}

export function render() {
  return `${JSON.stringify(build(), null, 2)}\n`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  writeFileSync(FILE, render());
  console.log(`Wrote ${FILE}`);
}
