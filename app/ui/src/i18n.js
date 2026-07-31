/* Bilingual dictionaries, fetched rather than bundled.

   They stay real JSON files under `public/` (copied verbatim into `dist/`)
   for two reasons that outrank the saved request: `app/tests/test_ui.py`
   sweeps every `append_audit(action=...)` in the app and demands a matching
   `action_<name>` key in BOTH files, which needs them to be readable
   documents rather than a compiled artifact; and they keep serving from
   `/ui/i18n/<lang>.json`, the URL the shipped end-to-end check already
   probes.

   A failed load leaves the dictionary empty and `t()` answers with the key
   itself - the classic tree's behaviour. Rendering the key is ugly; a page
   that refuses to paint because a label file was slow is worse. */

export const LANGS = ["en", "zh"];

export function initialLang() {
  const stored = localStorage.getItem("panel_lang");
  if (LANGS.includes(stored)) return stored;
  const nav = (navigator.language || "").toLowerCase();
  return nav.startsWith("zh") ? "zh" : "en";
}

export function rememberLang(lang) {
  localStorage.setItem("panel_lang", lang);
}

export async function loadDict(lang) {
  try {
    const res = await fetch(`${import.meta.env.BASE_URL}i18n/${lang}.json`);
    if (!res.ok) return {};
    return await res.json();
  } catch {
    return {};
  }
}

export function translator(dict) {
  return (key) => (dict && dict[key]) || key;
}

// `zh-CN` rather than `zh`: the document language drives font selection and
// line breaking, and the generic tag leaves both to the browser's guess.
export function htmlLang(lang) {
  return lang === "zh" ? "zh-CN" : "en";
}
