(() => {
  const current = new URL(window.location.href);
  const explicit = current.searchParams.get("lang");
  const isSupported = (language) => language === "zh" || language === "en";
  let preferred = isSupported(explicit) ? explicit : null;

  try {
    if (preferred) {
      localStorage.setItem("photofind.language", preferred);
    } else {
      preferred = localStorage.getItem("photofind.language");
    }
  } catch {
    // Explicit language links still work when browser storage is blocked.
  }

  if (!isSupported(preferred)) {
    const language = navigator.languages?.[0] || navigator.language || "en";
    preferred = /^zh(?:-|$)/i.test(language) ? "zh" : "en";
  }

  const displayed = document.documentElement.lang.startsWith("zh") ? "zh" : "en";
  if (preferred === displayed) return;

  // Resolve from the asset URL to support both /PhotoFind/ and a domain root.
  const base = new URL("../", document.currentScript.src);
  const target = new URL(preferred === "en" ? "en/" : "./", base);
  target.search = current.search;
  target.hash = current.hash;
  window.location.replace(target.href);
})();
