const filename = "embeddinggemma-2-text-vision-440m.litertlm";
const sha256 = "92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0";

export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname !== `/${sha256}/${filename}`) {
      return new Response("Not found", { status: 404 });
    }
    if (!["GET", "HEAD"].includes(request.method)) {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    let object = await env.MODELS.head(filename);
    if (!object) return new Response("Not found", { status: 404 });
    if (object.size !== 387710976 || object.customMetadata?.sha256 !== sha256) {
      return new Response("Model unavailable", { status: 503 });
    }
    const headers = {
        "Content-Type": "application/octet-stream",
        "Content-Length": String(object.size),
        "Cache-Control": "public, max-age=31536000, immutable",
        "ETag": object.httpEtag,
        "X-Content-Type-Options": "nosniff",
        "Accept-Ranges": "bytes",
    };
    if (request.method === "HEAD") return new Response(null, { headers });
    let range;
    const requested = request.headers.get("Range");
    const ifRange = request.headers.get("If-Range");
    if (requested && (!ifRange || ifRange === object.httpEtag)) {
      const match = /^bytes=(\d+)-(\d*)$/.exec(requested);
      const start = match ? Number(match[1]) : NaN;
      const end = match?.[2] ? Math.min(Number(match[2]), object.size - 1) : object.size - 1;
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= object.size || end < start) {
        return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${object.size}` } });
      }
      range = { offset: start, length: end - start + 1 };
      headers["Content-Range"] = `bytes ${start}-${end}/${object.size}`;
      headers["Content-Length"] = String(range.length);
    }
    const etag = object.httpEtag;
    object = await env.MODELS.get(filename, range ? { range } : undefined);
    if (!object || object.httpEtag !== etag || object.size !== 387710976 || object.customMetadata?.sha256 !== sha256) {
      return new Response("Model unavailable", { status: 503 });
    }
    return new Response(object.body, { status: range ? 206 : 200, headers });
  },
};
