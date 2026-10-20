import assert from "node:assert/strict";
import worker from "./worker.mjs";

const path = "/92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0/embeddinggemma-2-text-vision-440m.litertlm";
let reads = 0;
let object = {
  size: 387710976,
  customMetadata: { sha256: path.split("/")[1] },
  httpEtag: '"test"',
  body: "model",
};
const env = { MODELS: {
  async get(key) { reads++; assert.equal(key, path.split("/")[2]); return object; },
  async head(key) { reads++; assert.equal(key, path.split("/")[2]); return object; },
} };
const fetch = (pathname = path, method = "GET") =>
  worker.fetch(new Request(`https://models.example${pathname}`, { method }), env);
assert.equal((await fetch("/another-private-file")).status, 404);
assert.equal((await fetch("/", "GET")).status, 404);
assert.equal((await fetch(path, "PUT")).status, 405);
assert.equal(reads, 0);
let response = await fetch();
assert.equal(response.status, 200);
assert.equal(response.headers.get("Content-Length"), "387710976");
assert.equal(await response.text(), "model");
assert.equal(await (await fetch(path, "HEAD")).text(), "");
object = { ...object, size: 1 };
assert.equal((await fetch()).status, 503);
object = { ...object, size: 387710976, customMetadata: {} };
assert.equal((await fetch()).status, 503);
object = null;
assert.equal((await fetch()).status, 404);
console.log("Model download endpoint checks passed.");
