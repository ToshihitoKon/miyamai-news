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
