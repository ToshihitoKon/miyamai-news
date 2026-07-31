import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "./index.js";

async function subscribe(body) {
  const request = new Request("https://example.com/subscribe", {
    method: "POST",
    body: JSON.stringify(body),
  });
  return worker.fetch(request, env);
}

async function sign(body, secret) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return btoa(String.fromCharCode(...new Uint8Array(signature)));
}

async function notify(body, { secret = env.NOTIFY_SHARED_SECRET } = {}) {
  const text = JSON.stringify(body);
  const request = new Request("https://example.com/notify", {
    method: "POST",
    headers: { "x-signature": await sign(text, secret) },
    body: text,
  });
  return worker.fetch(request, env);
}

function toBase64Url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// web-push の暗号化は有効な P-256 鍵を要求するため、テスト用の購読キーは
// 適当な文字列ではなく実際に生成した鍵から作る。
async function generatePushKeys() {
  const keyPair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, [
    "deriveBits",
  ]);
  const rawPublicKey = await crypto.subtle.exportKey("raw", keyPair.publicKey);
  const auth = crypto.getRandomValues(new Uint8Array(16));
  return { p256dh: toBase64Url(new Uint8Array(rawPublicKey)), auth: toBase64Url(auth) };
}

describe("POST /subscribe", () => {
  beforeEach(async () => {
    await env.SUBSCRIPTIONS.prepare("DELETE FROM subscriptions").run();
  });

  it("stores a new subscription", async () => {
    const response = await subscribe({
      endpoint: "https://fcm.googleapis.com/fcm/send/1",
      keys: { p256dh: "p256dh-value", auth: "auth-value" },
    });

    expect(response.status).toBe(204);
    const { results } = await env.SUBSCRIPTIONS.prepare("SELECT * FROM subscriptions").all();
    expect(results).toHaveLength(1);
    expect(results[0].endpoint).toBe("https://fcm.googleapis.com/fcm/send/1");
  });

  it("upserts when the same endpoint subscribes again with new keys", async () => {
    await subscribe({ endpoint: "https://fcm.googleapis.com/fcm/send/1", keys: { p256dh: "old", auth: "old" } });
    await subscribe({ endpoint: "https://fcm.googleapis.com/fcm/send/1", keys: { p256dh: "new", auth: "new" } });

    const { results } = await env.SUBSCRIPTIONS.prepare("SELECT * FROM subscriptions").all();
    expect(results).toHaveLength(1);
    expect(results[0].p256dh).toBe("new");
  });

  it("rejects a request missing keys", async () => {
    const response = await subscribe({ endpoint: "https://fcm.googleapis.com/fcm/send/1" });
    expect(response.status).toBe(400);
  });

  it("rejects a non-JSON body", async () => {
    const request = new Request("https://example.com/subscribe", {
      method: "POST",
      body: "not json",
    });
    const response = await worker.fetch(request, env);
    expect(response.status).toBe(400);
  });

  // endpoint はブラウザの pushManager.subscribe() が返す値で、必ず既知の Push
  // サービスのオリジンを指す。ここを検証しないと、任意のホストを endpoint として
  // 登録でき、/notify がそこへ無制限に fetch してしまう。
  it("rejects an endpoint whose origin is not a known push service", async () => {
    const response = await subscribe({
      endpoint: "https://attacker.example/collect",
      keys: { p256dh: "p256dh-value", auth: "auth-value" },
    });

    expect(response.status).toBe(400);
    const { results } = await env.SUBSCRIPTIONS.prepare("SELECT * FROM subscriptions").all();
    expect(results).toHaveLength(0);
  });

  it("rejects an endpoint that is not a valid URL", async () => {
    const response = await subscribe({
      endpoint: "not-a-url",
      keys: { p256dh: "p256dh-value", auth: "auth-value" },
    });

    expect(response.status).toBe(400);
  });
});

describe("POST /notify", () => {
  beforeEach(async () => {
    await env.SUBSCRIPTIONS.prepare("DELETE FROM subscriptions").run();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("rejects a request with an invalid signature", async () => {
    const response = await notify({ title: "t", body: "b", url: "https://example.com" }, { secret: "wrong-secret" });
    expect(response.status).toBe(401);
  });

  it("rejects a request with a valid signature but a malformed payload", async () => {
    const response = await notify({ title: "t" });
    expect(response.status).toBe(400);
  });

  it("sends a push message to every subscriber", async () => {
    const keys = await generatePushKeys();
    await subscribe({ endpoint: "https://fcm.googleapis.com/fcm/send/alive", keys });

    const sentEndpoints = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      sentEndpoints.push(new Request(input).url);
      return new Response(null, { status: 201 });
    });

    const response = await notify({ title: "新着ニュースが公開されました", body: "2026-07-14 昼", url: "https://example.com/episode" });

    expect(response.status).toBe(204);
    expect(sentEndpoints).toEqual(["https://fcm.googleapis.com/fcm/send/alive"]);
  });

  it("deletes subscriptions the push service reports as gone", async () => {
    const keys = await generatePushKeys();
    await subscribe({ endpoint: "https://fcm.googleapis.com/fcm/send/dead", keys });

    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(null, { status: 410 }));

    await notify({ title: "t", body: "b", url: "https://example.com" });

    const { results } = await env.SUBSCRIPTIONS.prepare("SELECT * FROM subscriptions").all();
    expect(results).toHaveLength(0);
  });

  it("keeps subscriptions the push service still accepts", async () => {
    const keys = await generatePushKeys();
    await subscribe({ endpoint: "https://fcm.googleapis.com/fcm/send/alive", keys });

    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(null, { status: 201 }));

    await notify({ title: "t", body: "b", url: "https://example.com" });

    const { results } = await env.SUBSCRIPTIONS.prepare("SELECT * FROM subscriptions").all();
    expect(results).toHaveLength(1);
  });

  // 1件の不正な購読（web-push の暗号化が失敗する等）が Promise.all 全体を巻き込んで
  // reject すると、他の正常な購読者への配信・期限切れ購読の削除まで巻き添えで
  // 止まってしまう。個別に握りつぶして他へ影響しないことを確認する。
  it("still delivers to other subscribers and cleans up expired ones when one subscription is broken", async () => {
    const goodKeys = await generatePushKeys();
    await env.SUBSCRIPTIONS.prepare(
      "INSERT INTO subscriptions (endpoint, p256dh, auth) VALUES (?, ?, ?)",
    )
      .bind("https://fcm.googleapis.com/fcm/send/broken", "not-valid-base64!!", "also-not-valid!!")
      .run();
    await subscribe({ endpoint: "https://fcm.googleapis.com/fcm/send/alive", keys: goodKeys });
    await subscribe({ endpoint: "https://fcm.googleapis.com/fcm/send/dead", keys: goodKeys });

    const sentEndpoints = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = new Request(input).url;
      sentEndpoints.push(url);
      return new Response(null, { status: url.endsWith("/dead") ? 410 : 201 });
    });

    const response = await notify({ title: "t", body: "b", url: "https://example.com" });

    expect(response.status).toBe(204);
    expect(sentEndpoints).toEqual(["https://fcm.googleapis.com/fcm/send/alive", "https://fcm.googleapis.com/fcm/send/dead"]);

    const { results } = await env.SUBSCRIPTIONS.prepare("SELECT endpoint FROM subscriptions ORDER BY endpoint").all();
    expect(results.map((r) => r.endpoint)).toEqual(["https://fcm.googleapis.com/fcm/send/alive", "https://fcm.googleapis.com/fcm/send/broken"]);
  });
});
