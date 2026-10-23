import assert from "node:assert/strict";
import worker from "./worker.mjs";

const path = "/92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0/embeddinggemma-2-text-vision-440m.litertlm";
let reads = 0;
let getOptions;
let object = {
  size: 387710976,
  customMetadata: { sha256: path.split("/")[1] },
  httpEtag: '"test"',
  body: "model",
};
const env = { MODELS: {
  async get(key, options) { reads++; getOptions = options; assert.equal(key, path.split("/")[2]); return object; },
  async head(key) { reads++; assert.equal(key, path.split("/")[2]); return object; },
} };
const fetch = (pathname = path, method = "GET", headers = {}) =>
  worker.fetch(new Request(`https://models.example${pathname}`, { method, headers }), env);
assert.equal((await fetch("/another-private-file")).status, 404);
assert.equal((await fetch("/", "GET")).status, 404);
assert.equal((await fetch(path, "PUT")).status, 405);
assert.equal(reads, 0);
let response = await fetch();
assert.equal(response.status, 200);
assert.equal(response.headers.get("Content-Length"), "387710976");
assert.equal(await response.text(), "model");
assert.equal(await (await fetch(path, "HEAD")).text(), "");
response = await fetch(path, "GET", { Range: "bytes=8388608-16777215" });
assert.equal(response.status, 206);
assert.deepEqual(getOptions, { range: { offset: 8388608, length: 8388608 } });
assert.equal(response.headers.get("Content-Range"), "bytes 8388608-16777215/387710976");
assert.equal(response.headers.get("Content-Length"), "8388608");
assert.equal(response.headers.get("Accept-Ranges"), "bytes");
response = await fetch(path, "GET", { Range: "bytes=387710972-" });
assert.equal(response.headers.get("Content-Range"), "bytes 387710972-387710975/387710976");
for (const range of ["bytes=387710976-", "bytes=4-2", "bytes=0-2,4-6", "garbage", "bytes=9007199254740992-"]) {
  const before = getOptions;
  response = await fetch(path, "GET", { Range: range });
  assert.equal(response.status, 416);
  assert.equal(response.headers.get("Content-Range"), "bytes */387710976");
  assert.equal(getOptions, before);
}
response = await fetch(path, "GET", { Range: "bytes=4-", "If-Range": '"old"' });
assert.equal(response.status, 200);
assert.equal(getOptions, undefined);
response = await fetch(path, "HEAD", { Range: "bytes=4-" });
assert.equal(response.status, 200);
assert.equal(response.headers.get("Content-Length"), "387710976");
object = { ...object, size: 1 };
assert.equal((await fetch()).status, 503);
object = { ...object, size: 387710976, customMetadata: {} };
assert.equal((await fetch()).status, 503);
object = null;
assert.equal((await fetch()).status, 404);
console.log("Model download endpoint checks passed.");
