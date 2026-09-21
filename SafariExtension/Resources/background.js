/* Qiuling for Safari — the toolbar button toggles the current page into the
 * Qiuling script: every text element gets the "Qiuling Reader" family and its
 * font-size/line-height doubled, with undo on the second tap.
 *
 * `QIULING_KEEP`, `qiulingCss` and `qiulingApply` below are the in-page
 * routine from `web/reader.js` in the qiuling repo (the one source for the
 * bookmarklet and the Chrome extension), carried verbatim; the only change is
 * the @font-face format, "truetype", because the phone's font is a TTF.
 *
 * The font itself comes from the app: the native handler
 * (SafariWebExtensionHandler.swift) reads the current TTF out of the shared
 * App Group container — or the copy bundled with this extension — and hands
 * it over as base64. It is cached in storage.local keyed by its sha and
 * refreshed on browser start, on install, and on a tap when the cache is more
 * than ten minutes old, so an over-the-air font update reaches Safari without a
 * reinstall. If native messaging fails outright the bundled TTF is used via
 * its extension URL. */

/* Things that must keep their own font: code, form fields, and the usual icon
 * fonts, which draw glyphs from letters and would turn into Qiuling marks. */
const QIULING_KEEP = ':is(' + [
  'svg', 'code', 'pre', 'kbd', 'samp', 'tt',
  'input', 'textarea', 'select', 'option', '[contenteditable]',
  '.material-icons', '.material-icons-outlined', '.material-symbols-outlined',
  '[class^="fa-"]', '[class*=" fa-"]', '.fa', '.fas', '.far', '.fab', '.glyphicon',
  '.icon', 'i[class*="icon"]', 'span[class*="icon"]',
].join(', ') + ')';

/* No case handling is needed: the font points A-Z at the same glyphs as a-z,
 * so `The` shapes to the `the` block on its own. Nor is any ligature
 * handling: the blocks are `rlig`, which a page's `letter-spacing` or
 * `font-variant-ligatures` cannot switch off. Letter-spacing is still reset
 * because tracked-out marks read badly, not because anything breaks. */
function qiulingCss(fontUrl) {
  const keep = QIULING_KEEP;
  return `
@font-face {
  font-family: "Qiuling Reader";
  src: url("${fontUrl}") format("truetype");
  font-display: block;
}
html body, html body *:not(${keep}):not(${keep} *) {
  font-family: "Qiuling Reader", system-ui, sans-serif !important;
  letter-spacing: normal !important;
}`;
}

/* Qiuling marks are dense, so the page is read at twice its own size. */
const QIULING_SCALE = 2;

/* Runs INSIDE the page — serialised into the tab by scripting.executeScript —
 * so it takes everything as arguments and touches nothing but the document.
 *
 * Scaling is done in JS rather than CSS because there is no CSS that means
 * "twice whatever this element's size already is": `2em` compounds through
 * nesting, and `font-size-adjust` would blow up the fallback digits too. So
 * every element's computed size is read first, then each is set to an
 * absolute doubled pixel value, with the previous inline value kept so the
 * second click can put it back exactly. */
function qiulingApply(id, css, keep, scale, on) {
  var W = window, style = document.getElementById(id);
  if (!on) {
    if (style) style.remove();
    var undo = W.__qiulingUndo || [];
    for (var i = 0; i < undo.length; i++) {
      var u = undo[i];
      for (var p in u.prev) {
        if (u.prev[p][0]) u.el.style.setProperty(p, u.prev[p][0], u.prev[p][1]);
        else u.el.style.removeProperty(p);
      }
      if (!u.el.getAttribute('style')) u.el.removeAttribute('style');
    }
    delete W.__qiulingUndo;
    return false;
  }
  if (style) return true;

  var els = document.querySelectorAll('body, body *'), snap = [];
  for (var j = 0; j < els.length; j++) {
    var e = els[j];
    if (e.closest(keep)) continue;
    var cs = getComputedStyle(e);
    snap.push([e, parseFloat(cs.fontSize), cs.lineHeight]);
  }
  var log = [];
  for (var k = 0; k < snap.length; k++) {
    var el = snap[k][0], prev = {};
    var set = function (prop, value) {
      prev[prop] = [el.style.getPropertyValue(prop), el.style.getPropertyPriority(prop)];
      el.style.setProperty(prop, value, 'important');
    };
    if (snap[k][1] > 0) set('font-size', snap[k][1] * scale + 'px');
    if (/px$/.test(snap[k][2])) set('line-height', parseFloat(snap[k][2]) * scale + 'px');
    log.push({ el: el, prev: prev });
  }
  W.__qiulingUndo = log;

  style = document.createElement('style');
  style.id = id;
  style.textContent = css;
  (document.head || document.documentElement).appendChild(style);
  return true;
}

/* Also runs inside the page: is the style currently applied there? */
function qiulingIsOn(id) {
  return Boolean(document.getElementById(id));
}

const STYLE_ID = 'qiuling-reader-style';
const BUNDLED_TTF = 'QiulingMorphWrite-Regular.ttf';
const FONT_MAX_AGE_MS = 10 * 60 * 1000;   // matches the native handler's interval

/* --- the font, from the app --------------------------------------------- */

async function askNativeForFont() {
  try {
    const reply = await browser.runtime.sendNativeMessage('application.id', { type: 'font' });
    if (reply && typeof reply.base64 === 'string' && reply.base64 && typeof reply.sha256 === 'string') {
      return { sha256: reply.sha256, base64: reply.base64 };
    }
    if (reply && reply.error) console.warn('Qiuling: native handler reported', reply.error);
  } catch (e) {
    console.warn('Qiuling: native messaging failed', e);
  }
  return null;
}

/* The cache in storage.local: `fontSha` names the current font, `font:<sha>`
 * holds its base64, `fontCheckedAt` is when native was last asked. */
async function currentFontFromCache() {
  const { fontSha, fontCheckedAt } = await browser.storage.local.get(['fontSha', 'fontCheckedAt']);
  if (!fontSha) return null;
  const key = 'font:' + fontSha;
  const got = await browser.storage.local.get(key);
  if (!got[key]) return null;
  return { sha256: fontSha, base64: got[key], checkedAt: fontCheckedAt || 0 };
}

async function refreshFont(force) {
  const cached = await currentFontFromCache();
  if (cached && !force && Date.now() - cached.checkedAt < FONT_MAX_AGE_MS) return cached;
  const fresh = await askNativeForFont();
  if (!fresh) return cached;
  const updates = { fontSha: fresh.sha256, fontCheckedAt: Date.now(), ['font:' + fresh.sha256]: fresh.base64 };
  await browser.storage.local.set(updates);
  if (cached && cached.sha256 !== fresh.sha256) await browser.storage.local.remove('font:' + cached.sha256);
  return { ...fresh, checkedAt: updates.fontCheckedAt };
}

function fontUrlFor(font) {
  return font ? 'data:font/ttf;base64,' + font.base64 : browser.runtime.getURL(BUNDLED_TTF);
}

/* --- the tab ------------------------------------------------------------ */

async function runInTab(tabId, func, args, allFrames) {
  const results = await browser.scripting.executeScript({
    target: { tabId, allFrames: Boolean(allFrames) },
    func,
    args,
  });
  const main = results && results.find((r) => r && r.frameId === 0);
  return main ? main.result : results && results[0] && results[0].result;
}

async function isOn(tabId) {
  try {
    return Boolean(await runInTab(tabId, qiulingIsOn, [STYLE_ID], false));
  } catch {
    return false;
  }
}

async function showState(tabId, on) {
  try {
    await browser.action.setBadgeText({ tabId, text: on ? 'ON' : '' });
    if (on) await browser.action.setBadgeBackgroundColor({ tabId, color: '#E4472D' });
    await browser.action.setTitle({ tabId, title: on ? 'Qiuling: on' : 'Qiuling' });
  } catch (e) {
    console.warn('Qiuling: could not update the button', e);
  }
}

async function setTab(tabId, on) {
  const css = on ? qiulingCss(fontUrlFor(await refreshFont(false))) : '';
  try {
    await runInTab(tabId, qiulingApply, [STYLE_ID, css, QIULING_KEEP, QIULING_SCALE, on], true);
  } catch (e) {
    // Safari's own pages, the reading list, PDFs and the like refuse injection.
    console.warn('Qiuling: could not reach the page', e);
    return false;
  }
  await showState(tabId, on);
  return true;
}

browser.action.onClicked.addListener(async (tab) => {
  if (!tab || tab.id == null) return;
  const on = !(await isOn(tab.id));
  await setTab(tab.id, on);
});

/* A navigation makes a fresh document, which is never styled. */
browser.tabs.onUpdated.addListener((tabId, info) => {
  if (info.status === 'loading') showState(tabId, false);
});

if (browser.runtime.onStartup) browser.runtime.onStartup.addListener(() => { refreshFont(true); });
browser.runtime.onInstalled.addListener(() => { refreshFont(true); });
