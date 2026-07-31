import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "./index.js";

async function subscribe(body) {
  const request = new Request("https://example.com/subscribe", {
    method: "POST",
    body: JSON.stringify(body),
  });
  return worker.fetch(request, env);
}

describe("POST /subscribe", () => {
  beforeEach(async () => {
    await env.SUBSCRIPTIONS.prepare("DELETE FROM subscriptions").run();
  });

  it("stores a new subscription", async () => {
    const response = await subscribe({
      endpoint: "https://push.example/1",
      keys: { p256dh: "p256dh-value", auth: "auth-value" },
    });

    expect(response.status).toBe(204);
    const { results } = await env.SUBSCRIPTIONS.prepare("SELECT * FROM subscriptions").all();
    expect(results).toHaveLength(1);
    expect(results[0].endpoint).toBe("https://push.example/1");
  });

  it("upserts when the same endpoint subscribes again with new keys", async () => {
    await subscribe({ endpoint: "https://push.example/1", keys: { p256dh: "old", auth: "old" } });
    await subscribe({ endpoint: "https://push.example/1", keys: { p256dh: "new", auth: "new" } });

    const { results } = await env.SUBSCRIPTIONS.prepare("SELECT * FROM subscriptions").all();
    expect(results).toHaveLength(1);
    expect(results[0].p256dh).toBe("new");
  });

  it("rejects a request missing keys", async () => {
    const response = await subscribe({ endpoint: "https://push.example/1" });
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
});
