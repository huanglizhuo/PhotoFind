const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { runInNewContext } = require("node:vm");

const source = readFileSync(join(__dirname, "../docs/assets/language.js"), "utf8");

function visit({
  base = "https://huanglizhuo.github.io/PhotoFind/",
  page = "",
  languages = ["en-US"],
  language = "en-US",
  saved = null,
  blocked = false,
} = {}) {
  let redirected;
  const context = {
    URL,
    navigator: { languages, language },
    document: {
      documentElement: { lang: page.startsWith("en/") ? "en" : "zh-Hans" },
      currentScript: { src: new URL("assets/language.js", base).href },
    },
    localStorage: {
      getItem(key) {
        assert.equal(key, "photofind.language");
        if (blocked) throw new Error("Storage blocked");
        return saved;
      },
      setItem(key, value) {
        assert.equal(key, "photofind.language");
        if (blocked) throw new Error("Storage blocked");
        saved = value;
      },
    },
    window: { location: {
      href: new URL(page, base).href,
      replace(url) { redirected = url; },
    } },
  };
  runInNewContext(source, context);
  return { redirected, saved };
}

for (const language of ["zh", "zh-CN", "zh-TW", "zh-HK", "zh-Hans", "ZH-hant"]) {
  test(`${language} defaults to Chinese`, () => {
    assert.equal(visit({ languages: [language] }).redirected, undefined);
    assert.equal(visit({ page: "en/", languages: [language] }).redirected,
      "https://huanglizhuo.github.io/PhotoFind/");
  });
}

for (const language of ["en-US", "ja-JP", "ko-KR", "de-DE", "fr-FR"]) {
  test(`${language} defaults to English without a redirect loop`, () => {
    assert.equal(visit({ languages: [language] }).redirected,
      "https://huanglizhuo.github.io/PhotoFind/en/");
    assert.equal(visit({ page: "en/", languages: [language] }).redirected, undefined);
  });
}

test("the first preferred browser language wins", () => {
  assert.ok(visit({ languages: ["en-US", "zh-CN"] }).redirected);
  assert.equal(visit({ languages: ["zh-CN", "en-US"] }).redirected, undefined);
  assert.equal(visit({ languages: [], language: "zh-CN" }).redirected, undefined);
});

test("manual selection takes priority and persists across visits", () => {
  assert.deepEqual(visit({ page: "?lang=zh", saved: "en" }),
    { redirected: undefined, saved: "zh" });
  assert.equal(visit({ saved: "zh" }).redirected, undefined);
  const english = visit({ page: "en/?lang=en", languages: ["zh-CN"] });
  assert.deepEqual(english, { redirected: undefined, saved: "en" });
  assert.ok(visit({ languages: ["zh-CN"], saved: english.saved }).redirected);
});

test("storage restrictions do not prevent automatic or manual selection", () => {
  assert.ok(visit({ blocked: true }).redirected);
  assert.equal(visit({ blocked: true, page: "?lang=zh" }).redirected, undefined);
  assert.equal(visit({ blocked: true, page: "en/?lang=en", languages: ["zh-CN"] }).redirected, undefined);
});

test("invalid preferences fall back to browser language", () => {
  assert.equal(visit({ page: "?lang=other", saved: "other", languages: ["zh-TW"] }).redirected, undefined);
  assert.ok(visit({ languages: [], language: "" }).redirected);
});

test("redirects preserve parameters and anchors on either hosting path", () => {
  for (const base of ["https://huanglizhuo.github.io/PhotoFind/", "https://photofind.clothpath.com/"]) {
    assert.equal(visit({ base, page: "?source=share#features" }).redirected,
      `${base}en/?source=share#features`);
    assert.equal(visit({ base, page: "en/?source=share#privacy", languages: ["zh-CN"] }).redirected,
      `${base}?source=share#privacy`);
  }
});
