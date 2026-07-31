import webpush from "web-push";

export async function handleSubscribe(request, env) {
  let payload;
  try {
    payload = await request.json();
  } catch {
    return new Response("Bad Request", { status: 400 });
  }

  const { endpoint, keys } = payload ?? {};
  if (typeof endpoint !== "string" || !keys || typeof keys.p256dh !== "string" || typeof keys.auth !== "string") {
    return new Response("Bad Request", { status: 400 });
  }

  await env.SUBSCRIPTIONS.prepare(
    `INSERT INTO subscriptions (endpoint, p256dh, auth) VALUES (?, ?, ?)
     ON CONFLICT(endpoint) DO UPDATE SET p256dh = excluded.p256dh, auth = excluded.auth`,
  )
    .bind(endpoint, keys.p256dh, keys.auth)
    .run();

  return new Response(null, { status: 204 });
}

async function verifySignature(request, secret) {
  const signatureHeader = request.headers.get("x-signature");
  if (!signatureHeader) return { ok: false, body: null };

  const body = await request.text();
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );

  let signatureBytes;
  try {
    signatureBytes = Uint8Array.from(atob(signatureHeader), (c) => c.charCodeAt(0));
  } catch {
    return { ok: false, body };
  }

  const ok = await crypto.subtle.verify("HMAC", key, signatureBytes, new TextEncoder().encode(body));
  return { ok, body };
}

export async function handleNotify(request, env) {
  const { ok, body } = await verifySignature(request, env.NOTIFY_SHARED_SECRET);
  if (!ok) return new Response("Unauthorized", { status: 401 });

  let payload;
  try {
    payload = JSON.parse(body);
  } catch {
    return new Response("Bad Request", { status: 400 });
  }

  const { title, body: notificationBody, url } = payload ?? {};
  if (typeof title !== "string" || typeof notificationBody !== "string" || typeof url !== "string") {
    return new Response("Bad Request", { status: 400 });
  }

  webpush.setVapidDetails(env.VAPID_SUBJECT, env.VAPID_PUBLIC_KEY, env.VAPID_PRIVATE_KEY);

  const { results } = await env.SUBSCRIPTIONS.prepare("SELECT endpoint, p256dh, auth FROM subscriptions").all();

  const expiredEndpoints = [];
  await Promise.all(
    results.map(async (row) => {
      try {
        const subscription = { endpoint: row.endpoint, keys: { p256dh: row.p256dh, auth: row.auth } };
        const requestDetails = webpush.generateRequestDetails(
          subscription,
          JSON.stringify({ title, body: notificationBody, url }),
        );

        const response = await fetch(requestDetails.endpoint, {
          method: requestDetails.method,
          headers: requestDetails.headers,
          body: requestDetails.body,
        });

        if (response.status === 404 || response.status === 410) {
          expiredEndpoints.push(row.endpoint);
        }
      } catch (error) {
        // 1件の不正な購読・到達不能ホストが原因で Promise.all 全体が
        // reject すると、他の全購読者への配信と期限切れ購読の削除が
        // 巻き添えで止まってしまうため、ここで個別に握りつぶす。
        console.error(`push send failed for ${row.endpoint}: ${error.message}`);
      }
    }),
  );

  if (expiredEndpoints.length > 0) {
    const placeholders = expiredEndpoints.map(() => "?").join(", ");
    await env.SUBSCRIPTIONS.prepare(`DELETE FROM subscriptions WHERE endpoint IN (${placeholders})`)
      .bind(...expiredEndpoints)
      .run();
  }

  return new Response(null, { status: 204 });
}
