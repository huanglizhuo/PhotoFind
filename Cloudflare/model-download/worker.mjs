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
    const object = await env.MODELS[request.method === "HEAD" ? "head" : "get"](filename);
    if (!object) return new Response("Not found", { status: 404 });
    if (object.size !== 387710976 || object.customMetadata?.sha256 !== sha256) {
      return new Response("Model unavailable", { status: 503 });
    }
    return new Response(request.method === "HEAD" ? null : object.body, {
      headers: {
        "Content-Type": "application/octet-stream",
        "Content-Length": String(object.size),
        "Cache-Control": "public, max-age=31536000, immutable",
        "ETag": object.httpEtag,
        "X-Content-Type-Options": "nosniff",
      },
    });
  },
};
