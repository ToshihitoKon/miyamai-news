import { handleSubscribe } from './web_push.js';

const SERVABLE_PREFIXES = ['episodes/', 'assets/'];

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);

    if (request.method === 'POST' && pathname === '/subscribe') {
      return handleSubscribe(request, env);
    }

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method Not Allowed', {
        status: 405,
        headers: { Allow: 'GET, HEAD' },
      });
    }

    const key = decodeURIComponent(new URL(request.url).pathname.slice(1));

    const servable = SERVABLE_PREFIXES.some((p) => key.startsWith(p));
    if (!servable) return new Response('Not Found', { status: 404 });

    const object = await env.EPISODES.get(key, {
      onlyIf: request.headers,
      range: request.headers,
    });
    if (object === null) return new Response('Not Found', { status: 404 });

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set('etag', object.httpEtag);
    headers.set('accept-ranges', 'bytes');
    if (!headers.has('cache-control')) {
      headers.set('cache-control', 'public, max-age=300');
    }

    if (!('body' in object)) {
      const precondition =
        request.headers.has('if-match') || request.headers.has('if-unmodified-since');
      return new Response(undefined, { status: precondition ? 412 : 304, headers });
    }

    const ranged = request.headers.has('range') && object.range;
    if (ranged) {
      const offset = object.range.offset ?? 0;
      const length = object.range.length ?? object.size - offset;
      headers.set('content-range', `bytes ${offset}-${offset + length - 1}/${object.size}`);
      return new Response(object.body, { status: 206, headers });
    }

    return new Response(object.body, { status: 200, headers });
  },
};
