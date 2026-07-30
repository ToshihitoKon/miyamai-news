// audio プレフィックス配下（mp3 と、再生ページが拡張子を差し替えて引く
// .used.html / .used.txt / .transcript.txt）を R2 から返す。
// それ以外のパスは static assets が処理するのでここには来ない。
//
// _headers は run_worker_first のパスに適用されないため、Content-Type と
// Cache-Control はここで付ける。Content-Type は R2 オブジェクトのメタデータ
// （Ruby 側が put 時に設定）を writeHttpMetadata で反映する。
export default {
  async fetch(request, env) {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method Not Allowed', {
        status: 405,
        headers: { Allow: 'GET, HEAD' },
      });
    }

    const key = decodeURIComponent(new URL(request.url).pathname.slice(1));

    const object = await env.AUDIO.get(key, {
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

    // body を持たない = If-None-Match 等の条件が不成立。
    const hasBody = 'body' in object;
    if (!hasBody) {
      return new Response(undefined, { status: object.size === undefined ? 412 : 304, headers });
    }

    if (object.range && 'offset' in object.range) {
      const offset = object.range.offset ?? 0;
      const length = object.range.length ?? object.size - offset;
      headers.set('content-range', `bytes ${offset}-${offset + length - 1}/${object.size}`);
      return new Response(object.body, { status: 206, headers });
    }

    return new Response(object.body, { status: 200, headers });
  },
};
