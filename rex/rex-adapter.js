// Rex adapter: runs a Rex component (WidgetMetadata + loadList/loadDetail/
// search/loadResource) inside the TVBox QuickJS prelude and translates TVBox
// catalog calls into Rex handler calls, and back into TVBox JSON.
//
// Loaded via ScriptSession.start(module: "assets://rex/rex-adapter.js")
// with the component source supplied as host('module', 'rex://component').
// The adapter receives exactly the params TVBox sends (__tvbox.call):
//   home   {}                              -> first list module, page 1
//   list   {pg, ac=detail, t=moduleId, filters?}
//   detail {ac=detail, ids=link}
//   search {wd=keyword, pg, quick?}
//   play   {play=address, flag=lineName, detailID=link}
// and returns {result: "<TVBox JSON>"} or {error: "<message>"}.
//
// v1 limits, stated plainly:
//   - TMDB is not available: Widget.tmdb.get rejects with a readable error.
//   - Widget.dom is not available: use Widget.html.load (cheerio).
//   - globalParams use the component's own defaults only (no edit UI yet).
//   - Detail enumerates play lines by calling loadResource once; the URLs
//     from that call are DISCARDED and re-fetched at play time, so a signed
//     address is never played stale. If that call fails, detail falls back
//     to a single generic "播放" episode and play retries loadResource.
import * as cheerio from 'assets://js/lib/cheerio.min.js';

const host = globalThis.__host;

function fail(message) { throw new Error('[rex] ' + message); }

// --- Widget ---------------------------------------------------------------
function httpCall(method, url, body, opts) {
  opts = opts || {};
  const headers = {};
  for (const k of Object.keys(opts.headers || {})) headers[k] = String(opts.headers[k]);
  let bodyStr = null;
  if (body != null) {
    if (typeof body === 'string') bodyStr = body;
    else {
      bodyStr = JSON.stringify(body);
      if (!('Content-Type' in headers) && !('content-type' in headers)) headers['Content-Type'] = 'application/json';
    }
  }
  let u = String(url);
  if (opts.params) {
    const qs = new URLSearchParams(opts.params).toString();
    if (qs) u += (u.indexOf('?') >= 0 ? '&' : '?') + qs;
  }
  const payload = {
    url: u, method: String(method).toUpperCase(), headers, body: bodyStr, bodyBase64: null,
    timeout: 20000, racers: 1, hedge: 0,
    redirect: opts.allow_redirects !== false, encoding: 'utf-8', binary: false,
  };
  const ans = JSON.parse(host('http', JSON.stringify(payload)));
  if (ans.failed) fail(ans.failed);
  if (ans.code >= 400) fail('HTTP ' + ans.code + ' ' + u);
  let data = ans.content != null ? ans.content : '';
  try { data = JSON.parse(data); } catch (e) { /* keep as string */ }
  return { data, status: ans.code, headers: ans.headers || {} };
}

const __rexCache = new Map();
function cacheKey(a, b) { return b === undefined ? String(a) : String(a) + ':' + String(b); }

globalThis.Widget = {
  http: {
    get: (url, opts) => Promise.resolve(httpCall('GET', url, null, opts)),
    post: (url, body, opts) => Promise.resolve(httpCall('POST', url, body, opts)),
  },
  html: { load: (html) => cheerio.load(String(html != null ? html : '')) },
  dom: {
    parse: () => { throw new Error('[rex] Widget.dom is not supported in Finch Player v1; use Widget.html.load'); },
    select: () => { throw new Error('[rex] Widget.dom is not supported in Finch Player v1; use Widget.html.load'); },
  },
  storage: {
    get: (key) => { const v = host('local', JSON.stringify(['get', 'rex', String(key)])); return v === '' ? undefined : v; },
    set: (key, value) => { host('local', JSON.stringify(['set', 'rex', String(key), String(value)])); },
    remove: (key) => { host('local', JSON.stringify(['delete', 'rex', String(key)])); },
  },
  sharedCache: {
    get: (a, b) => { const v = __rexCache.get(cacheKey(a, b)); return v === undefined ? null : v; },
    set: (a, b, c) => { if (c === undefined) __rexCache.set(cacheKey(a), b); else __rexCache.set(cacheKey(a, b), c); },
    remove: (a, b) => { __rexCache.delete(cacheKey(a, b)); },
  },
  tmdb: {
    get: () => Promise.reject(new Error('[rex] TMDB is not supported in Finch Player v1')),
  },
};

// --- Component ------------------------------------------------------------
let META = null;

function handler(name) {
  const fn = globalThis[name];
  if (typeof fn !== 'function') fail('component does not define ' + name);
  return fn;
}

/// List modules only: stream/subtitle/danmu modules are not categories.
function listModules() {
  return (META.modules || []).filter((m) => m && m.type !== 'stream' && m.type !== 'subtitle' && m.type !== 'danmu'
    && m.id !== 'loadResource' && m.id !== 'loadSubtitle');
}

/// Component globalParams, filled with their own defaults; explicit params win.
function globalParams(params) {
  const out = { ...(params || {}) };
  for (const gp of (META.globalParams || [])) {
    if (gp && gp.name && out[gp.name] === undefined) out[gp.name] = gp.value;
  }
  return out;
}

/// Builds a handler's params from its module/search param defs:
/// constant -> value, page -> page, enumeration -> first option,
/// input/count -> its value (or the keyword for search), genreId/peopleId
/// and any other caller-supplied keys pass through untouched.
function buildParams(defs, page, extra) {
  const p = {};
  for (const def of (defs || [])) {
    if (!def || !def.name) continue;
    if (def.type === 'constant') p[def.name] = def.value;
    else if (def.type === 'page') p[def.name] = page;
    else if (def.type === 'enumeration') {
      const first = def.enumOptions && def.enumOptions[0];
      p[def.name] = (first && first.value != null) ? first.value : def.value;
    } else if (def.type === 'input' || def.type === 'count') {
      if (extra && extra[def.name] != null) p[def.name] = extra[def.name];
      else if (def.value != null) p[def.name] = def.value;
    }
  }
  for (const k of Object.keys(extra || {})) if (extra[k] != null && p[k] === undefined) p[k] = extra[k];
  return globalParams(p);
}

// --- TVBox mapping ---------------------------------------------------------
function picOf(it) { return it.coverUrl || it.posterPath || it.backdropPath || ''; }

function mapListItem(it) {
  return {
    vod_id: String(it.link != null ? it.link : (it.id != null ? it.id : '')),
    vod_name: String(it.title || ''),
    vod_pic: picOf(it),
    vod_remarks: String(it.releaseDate || (it.rating != null ? String(it.rating) : '')),
  };
}

function mapDetail(it, link) {
  const pic = picOf(it);
  const d = {
    vod_id: String(link),
    vod_name: String(it.title || ''),
    vod_pic: pic,
    vod_content: String(it.description || ''),
    vod_actor: (it.peoples || []).map((p) => p.title).filter(Boolean).join(','),
    vod_class: (it.genreItems || []).map((g) => g.title).filter(Boolean).join(','),
  };
  const year = String(it.releaseDate || '').match(/^\d{4}/);
  if (year) d.vod_year = year[0];
  if (it.videoUrl) {
    // Direct-link detail: one "直连" line whose address IS the stream URL.
    d.vod_play_from = '直连';
    d.vod_play_url = '直连$' + String(it.videoUrl);
  }
  return d;
}

/// One episode per line, addressed by the detail link itself: the adapter
/// re-resolves the line at play time via loadResource, so the URLs from the
/// detail-time enumeration are never played.
function episodesForLines(lines, link) {
  const names = lines.map((l) => String(l.name || '播放'));
  return {
    vod_play_from: names.join('$$$'),
    vod_play_url: names.map((n) => n + '$' + link).join('$$$'),
  };
}

// --- Ops ------------------------------------------------------------------
async function homeOp() {
  const modules = listModules();
  const first = modules[0];
  let items = [];
  if (first) {
    const fn = handler(first.functionName || 'loadList');
    const out = await fn(buildParams(first.params, 1, {}));
    items = Array.isArray(out) ? out : [];
  }
  return {
    class: modules.map((m) => ({ type_id: String(m.id), type_name: String(m.title || m.id) })),
    list: items.map(mapListItem),
    pagecount: items.length ? 2 : 1,
  };
}

async function listOp(params) {
  const modules = listModules();
  const module = modules.find((m) => String(m.id) === String(params.t || '')) || modules[0];
  if (!module) return { class: [], list: [], pagecount: 1 };
  const page = Math.max(1, parseInt(params.pg || '1', 10) || 1);
  let extra = {};
  try { extra = JSON.parse(params.filters || '{}') || {}; } catch (e) { extra = {}; }
  const fn = handler(module.functionName || 'loadList');
  const out = await fn(buildParams(module.params, page, extra));
  const items = Array.isArray(out) ? out : [];
  return { class: [], list: items.map(mapListItem), pagecount: items.length ? page + 1 : page };
}

async function searchOp(params) {
  const search = META.search;
  if (!search || !search.functionName) fail('this component has no search');
  const keyword = String(params.wd || '').trim();
  if (!keyword) return { class: [], list: [], pagecount: 1 };
  const page = Math.max(1, parseInt(params.pg || '1', 10) || 1);
  const fn = handler(search.functionName);
  const out = await fn(buildParams(search.params, page, { keyword }));
  const items = Array.isArray(out) ? out : [];
  return { class: [], list: items.map(mapListItem), pagecount: items.length ? page + 1 : page };
}

async function detailOp(params) {
  const link = String(params.ids || '');
  if (!link) fail('detail link is empty');
  const item = await handler('loadDetail')(link);
  if (!item) fail('详情不存在：' + link);
  const d = mapDetail(item, link);
  if (!item.videoUrl) {
    // Enumerate lines for the episodes; URLs are discarded, play re-fetches.
    try {
      const lines = await handler('loadResource')({ link });
      const arr = Array.isArray(lines) ? lines : (lines ? [lines] : []);
      if (arr.length) Object.assign(d, episodesForLines(arr, link));
    } catch (e) { /* fall through to the single generic episode */ }
    if (!d.vod_play_from) {
      d.vod_play_from = '播放';
      d.vod_play_url = '播放$' + link;
    }
  }
  return { class: [], list: [d], pagecount: 1 };
}

async function playOp(params) {
  const address = String(params.play || '');
  const flag = String(params.flag || '');
  const link = String(params.detailID || address);
  if (flag === '直连' && address) return { url: address };
  if (!link) fail('play link is empty');
  const lines = await handler('loadResource')({ link });
  const arr = Array.isArray(lines) ? lines : (lines ? [lines] : []);
  if (!arr.length) fail('本站无此影片的播放地址');
  const line = arr.find((l) => String(l.name || '') === flag) || arr[0];
  if (!line.url) fail('本站无此影片的播放地址');
  const out = { url: String(line.url) };
  const header = line.customHeaders || line.headers;
  if (header && typeof header === 'object') out.header = header;
  if (line.referer) out.referer = String(line.referer);
  return out;
}

// --- Entry ----------------------------------------------------------------
globalThis.__rex = {
  load() {
    try {
      (0, eval)(host('module', 'rex://component'));
      META = globalThis.WidgetMetadata;
      if (!META || typeof META !== 'object' || !Array.isArray(META.modules)) {
        fail('not a Rex component: WidgetMetadata.modules missing');
      }
      return { ready: true, title: META.title || '', id: META.id || '' };
    } catch (e) {
      return { error: String((e && e.message) || e), errorCode: 'script_error' };
    }
  },

  async call(input) {
    try {
      const params = input || {};
      let out;
      if (params.play != null && params.play !== '') out = await playOp(params);
      else if (params.ids != null && params.ids !== '') out = await detailOp(params);
      else if (params.wd != null && params.wd !== '') out = await searchOp(params);
      else if (params.t != null && params.t !== '') out = await listOp(params);
      else out = await homeOp();
      return { result: JSON.stringify(out) };
    } catch (e) {
      return { error: String((e && e.message) || e) };
    }
  },
};
