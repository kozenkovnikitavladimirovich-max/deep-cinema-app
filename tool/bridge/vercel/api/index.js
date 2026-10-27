// Deep Cinema — мост для Vercel. Сгенерирован из ../../worker.js (tool/bridge/make_vercel.py).

// Deep Cinema — мост (бесплатно, без карты). Один и тот же код работает
// на Cloudflare Workers, Deno Deploy и Vercel (там, где Cloudflare замедляют).
//
// Что умеет:
//   GET  /p?u=<адрес>      — открыть адрес сервиса описаний/картинок (TMDB, TVmaze, OMDb…),
//                            который заблокирован у провайдера. Только из списка ALLOWED.
//   POST /auth             — вход: {provider: "yandex"|"google", token: "<токен входа>"}.
//                            Мост сам проверяет токен у Яндекса/Google и выдаёт ключ сессии.
//   GET  /data             — списки, история и настройки пользователя (по ключу сессии).
//   PUT  /data             — сохранить их.
//   POST /register         — регистрация по почте: {email, password, name?}.
//   POST /login            — вход по почте: {email, password}.
//   GET  /ya               — сюда Яндекс возвращает пользователя после входа по QR-коду.
//   GET  /ya/poll?state=   — телевизор забирает код входа (одноразово).
//   POST /t                — открыть страницу трекера, который заблокирован у провайдера
//                            (только для приложения Deep Cinema: нужен заголовок x-dc-key).
//   GET  /                 — проверка: {"app":"deep-cinema-bridge"}.
//
// Нужно в настройках Worker'а:
//   • привязка KV с именем DATA (хранилище списков);
//   • секрет SESSION_SECRET — любая длинная случайная строка.

const ALLOWED = new Set([
  'api.themoviedb.org', 'api.tmdb.org', 'image.tmdb.org', 'media.themoviedb.org',
  'api.tvmaze.com', 'static.tvmaze.com', 'api.theintrodb.org', 'www.omdbapi.com',
]);

const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8', 'access-control-allow-origin': '*' };
const json = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: JSON_HEADERS });

const app = {
  async fetch(request, env, ctx) {
    env = await platformEnv(env);
    const url = new URL(request.url);
    try {
      if (url.pathname === '/' ) return json({ app: 'deep-cinema-bridge', kv: !!env.DATA, secret: !!env.SESSION_SECRET });
      if (url.pathname === '/p') return proxy(request, url, ctx);
      if (url.pathname === '/auth' && request.method === 'POST') return auth(request, env);
      if (url.pathname === '/data') return data(request, env);
      if (url.pathname === '/register' && request.method === 'POST') return register(request, env);
      if (url.pathname === '/login' && request.method === 'POST') return login(request, env);
      if (url.pathname === '/ya') return yaReturn(url, env);
      if (url.pathname === '/ya/poll') return yaPoll(url, env);
      if (url.pathname === '/t' && request.method === 'POST') return tracker(request);
      return json({ error: 'not found' }, 404);
    } catch (e) {
      return json({ error: String(e && e.message || e) }, 500);
    }
  },
};

// ── Посредник для заблокированных сервисов ─────────────────────────────

async function proxy(request, url, ctx) {
  const target = url.searchParams.get('u') || '';
  let t;
  try { t = new URL(target); } catch { return json({ error: 'bad url' }, 400); }
  if (t.protocol !== 'https:' || !ALLOWED.has(t.hostname)) return json({ error: 'host not allowed' }, 403);
  const headers = { 'user-agent': 'DeepCinema' };
  const auth = request.headers.get('authorization');
  if (auth) headers['authorization'] = auth;
  const accept = request.headers.get('accept');
  if (accept) headers['accept'] = accept;
  const isImage = t.hostname === 'image.tmdb.org' || t.hostname === 'media.themoviedb.org' || t.hostname === 'static.tvmaze.com';
  // Картинки и описания кешируются на серверах Cloudflare — меньше запросов и быстрее.
  const onCloudflare = typeof navigator !== 'undefined' && navigator.userAgent === 'Cloudflare-Workers';
  const r = await fetch(t.toString(), onCloudflare ? { headers, cf: { cacheEverything: true, cacheTtl: isImage ? 604800 : 3600 } } : { headers });
  const out = new Response(r.body, r);
  out.headers.set('access-control-allow-origin', '*');
  out.headers.set('cache-control', isImage ? 'public, max-age=604800' : 'public, max-age=3600');
  return out;
}

// ── Трекеры, заблокированные у провайдера ─────────────────────────────
// Приложение присылает запрос целиком (адрес, метод, заголовки, тело), мост выполняет его
// без перенаправлений и возвращает ответ как есть — cookie, адрес перенаправления, страницу.

const TRACKER_KEY = 'dc-trackers-v1';
const privateHost = (h) => /^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|0\.|\[?::1\]?$|\[?f[cd])/i.test(h) || h.endsWith('.local') || h.endsWith('.internal');

function toB64(buf) {
  const bytes = new Uint8Array(buf);
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

async function tracker(request) {
  if (request.headers.get('x-dc-key') !== TRACKER_KEY) return json({ error: 'forbidden' }, 403);
  const b = await request.json();
  let t;
  try { t = new URL(b.url); } catch { return json({ error: 'bad url' }); }
  if (!/^https?:$/.test(t.protocol) || privateHost(t.hostname)) return json({ error: 'адрес не разрешён' });
  const method = String(b.method || 'GET').toUpperCase();
  if (!['GET', 'POST', 'HEAD'].includes(method)) return json({ error: 'метод не разрешён' });
  const headers = new Headers();
  for (const [k, v] of Object.entries(b.headers || {})) {
    if (!/^(host|content-length|connection|cf-|x-forwarded|x-real-ip)/i.test(k)) headers.set(k, String(v));
  }
  let r;
  try {
    r = await fetch(t.toString(), {
      method,
      headers,
      body: b.body && method === 'POST' ? Uint8Array.from(atob(b.body), (c) => c.charCodeAt(0)) : undefined,
      redirect: 'manual',
    });
  } catch (e) {
    return json({ error: String(e && e.message || e) });
  }
  const buf = await r.arrayBuffer();
  if (buf.byteLength > 8 * 1024 * 1024) return json({ error: 'слишком большой ответ' });
  return json({
    status: r.status,
    location: r.headers.get('location'),
    cookies: typeof r.headers.getSetCookie === 'function' ? r.headers.getSetCookie() : (r.headers.get('set-cookie') ? [r.headers.get('set-cookie')] : []),
    type: r.headers.get('content-type') || '',
    body: toB64(buf),
  });
}

// ── Вход и сессии ──────────────────────────────────────────────────────

async function auth(request, env) {
  if (!env.SESSION_SECRET) return json({ error: 'мост не настроен: нет SESSION_SECRET' }, 500);
  const { provider, token } = await request.json();
  if (!token) return json({ error: 'нет токена' }, 400);
  let user;
  if (provider === 'yandex') {
    const r = await fetch('https://login.yandex.ru/info?format=json', { headers: { authorization: `OAuth ${token}` } });
    if (r.status !== 200) return json({ error: 'Яндекс не подтвердил вход' }, 401);
    const j = await r.json();
    user = { id: `yandex:${j.id}`, name: j.display_name || j.real_name || j.login || '', email: j.default_email || '' };
  } else if (provider === 'google') {
    const r = await fetch('https://www.googleapis.com/oauth2/v3/userinfo', { headers: { authorization: `Bearer ${token}` } });
    if (r.status !== 200) return json({ error: 'Google не подтвердил вход' }, 401);
    const j = await r.json();
    user = { id: `google:${j.sub}`, name: j.name || '', email: j.email || '' };
  } else {
    return json({ error: 'неизвестный способ входа' }, 400);
  }
  const exp = Date.now() + 180 * 24 * 3600 * 1000; // полгода
  const session = await sign(env.SESSION_SECRET, `${user.id}|${exp}`);
  return json({ session, user });
}

// ── Вход по почте и паролю ─────────────────────────────────────────────
// Пароль хранится только в виде необратимого отпечатка (PBKDF2). Забыли пароль —
// владелец моста удаляет запись «acct:почта» в хранилище, и человек регистрируется
// заново с той же почтой: списки и история при этом сохраняются.

const normEmail = (e) => String(e || '').trim().toLowerCase();
const okEmail = (e) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e) && e.length <= 200;

async function passHash(password, saltB64) {
  const salt = saltB64 ? Uint8Array.from(atob(saltB64), (c) => c.charCodeAt(0)) : crypto.getRandomValues(new Uint8Array(16));
  const key = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: 100000 }, key, 256);
  return { salt: btoa(String.fromCharCode(...salt)), hash: b64url(bits) };
}

async function session(env, user) {
  const exp = Date.now() + 365 * 24 * 3600 * 1000; // год
  return json({ session: await sign(env.SESSION_SECRET, `${user.id}|${exp}`), user });
}

async function register(request, env) {
  if (!env.SESSION_SECRET || !env.DATA) return json({ error: 'мост не настроен' }, 500);
  const b = await request.json();
  const email = normEmail(b.email);
  const password = String(b.password || '');
  if (!okEmail(email)) return json({ error: 'Проверьте адрес почты' }, 400);
  if (password.length < 6) return json({ error: 'Пароль — не короче 6 символов' }, 400);
  if (await env.DATA.get(`acct:${email}`)) return json({ error: 'Эта почта уже зарегистрирована — войдите' }, 409);
  const name = String(b.name || '').trim().slice(0, 60) || email.split('@')[0];
  const h = await passHash(password);
  await env.DATA.put(`acct:${email}`, JSON.stringify({ ...h, name, created: new Date().toISOString() }));
  return session(env, { id: `email:${email}`, name, email });
}

async function login(request, env) {
  if (!env.SESSION_SECRET || !env.DATA) return json({ error: 'мост не настроен' }, 500);
  const b = await request.json();
  const email = normEmail(b.email);
  const raw = await env.DATA.get(`acct:${email}`);
  if (!raw) return json({ error: 'Такой почты нет — зарегистрируйтесь' }, 404);
  const a = JSON.parse(raw);
  const h = await passHash(String(b.password || ''), a.salt);
  if (h.hash !== a.hash) return json({ error: 'Неверный пароль' }, 401);
  return session(env, { id: `email:${email}`, name: a.name || '', email });
}

// ── Вход Яндексом по QR-коду ───────────────────────────────────────────
// Телефон открывает страницу входа Яндекса, после «Разрешить» Яндекс возвращает его
// сюда с кодом. Мост на 10 минут кладёт код под случайной меткой, телевизор забирает.

const page = (title, text) => new Response(
  `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title>` +
  `<body style="margin:0;min-height:100vh;display:grid;place-items:center;font:18px system-ui;background:#111;color:#eee;text-align:center">` +
  `<div style="padding:24px"><div style="font-size:56px">${title === 'Готово' ? '✓' : '×'}</div><h1 style="font-size:28px">${title}</h1><p style="color:#aaa">${text}</p></div>`,
  { headers: { 'content-type': 'text/html; charset=utf-8' } });

async function yaReturn(url, env) {
  const state = url.searchParams.get('state') || '';
  if (!/^[A-Za-z0-9_-]{16,64}$/.test(state) || !env.DATA) return page('Ошибка', 'Неверная ссылка. Попробуйте ещё раз с телевизора.');
  const code = url.searchParams.get('code');
  await env.DATA.put(`ya:${state}`, code ? JSON.stringify({ code }) : JSON.stringify({ error: url.searchParams.get('error') || 'denied' }), { expirationTtl: 600 });
  return code ? page('Готово', 'Вход подтверждён. Вернитесь к Deep Cinema — он войдёт сам.') : page('Вход отменён', 'Можно закрыть эту страницу.');
}

async function yaPoll(url, env) {
  const state = url.searchParams.get('state') || '';
  if (!/^[A-Za-z0-9_-]{16,64}$/.test(state) || !env.DATA) return json({ error: 'bad state' }, 400);
  const v = await env.DATA.get(`ya:${state}`);
  if (!v) return json({ pending: true });
  await env.DATA.delete(`ya:${state}`);
  return new Response(v, { headers: JSON_HEADERS });
}

async function data(request, env) {
  if (!env.DATA) return json({ error: 'мост не настроен: нет хранилища DATA' }, 500);
  const key = await verify(env.SESSION_SECRET, (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, ''));
  if (!key) return json({ error: 'войдите заново' }, 401);
  if (request.method === 'GET') {
    const v = await env.DATA.get(`u:${key}`);
    return v ? new Response(v, { headers: JSON_HEADERS }) : json({ data: null });
  }
  if (request.method === 'PUT') {
    const body = await request.text();
    if (body.length > 20 * 1024 * 1024) return json({ error: 'слишком большие данные' }, 413);
    await env.DATA.put(`u:${key}`, JSON.stringify({ data: body, updated: new Date().toISOString() }));
    return json({ ok: true });
  }
  return json({ error: 'method' }, 405);
}

// Ключ сессии: «пользователь|срок|подпись» (подпись HMAC-SHA256 секретом моста).
const enc = new TextEncoder();
const b64url = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

async function hmac(secret, text) {
  const k = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64url(await crypto.subtle.sign('HMAC', k, enc.encode(text)));
}

async function sign(secret, payload) {
  return `${btoa(unescape(encodeURIComponent(payload))).replace(/=+$/, '')}.${await hmac(secret, payload)}`;
}

async function verify(secret, token) {
  if (!secret || !token || !token.includes('.')) return null;
  const [p, sig] = token.split('.');
  let payload;
  try { payload = decodeURIComponent(escape(atob(p))); } catch { return null; }
  if ((await hmac(secret, payload)) !== sig) return null;
  const [id, exp] = payload.split('|');
  if (!id || Number(exp) < Date.now()) return null;
  return id;
}

// ── Запуск на Deno Deploy ──────────────────────────────────────────────
// На Cloudflare хранилище и секрет приходят в env. На Deno — секрет из переменных
// окружения, хранилище — Deno KV (значения режем на куски: у KV предел 64 КБ).

let denoEnv = null;

async function platformEnv(env) {
  if (typeof Deno === 'undefined') return env || {};
  if (!denoEnv) {
    let kv = null;
    try { kv = await Deno.openKv(); } catch (_) { kv = null; }
    denoEnv = { SESSION_SECRET: Deno.env.get('SESSION_SECRET') || '', DATA: kv ? kvStore(kv) : null };
  }
  return denoEnv;
}

function kvStore(kv) {
  const PART = 20000; // символов в куске (кириллица — по 2 байта)
  return {
    async get(key) {
      const meta = await kv.get(['m', key]);
      if (!meta.value) return null;
      const n = meta.value.n;
      const parts = [];
      for (let i = 0; i < n; i++) {
        const c = await kv.get(['c', key, i]);
        if (c.value == null) return null;
        parts.push(c.value);
      }
      return parts.join('');
    },
    async put(key, value, opts) {
      const s = String(value);
      const n = Math.max(1, Math.ceil(s.length / PART));
      const o = opts && opts.expirationTtl ? { expireIn: opts.expirationTtl * 1000 } : undefined;
      for (let i = 0; i < n; i++) await kv.set(['c', key, i], s.slice(i * PART, (i + 1) * PART), o);
      await kv.set(['m', key], { n }, o);
    },
    async delete(key) {
      const meta = await kv.get(['m', key]);
      await kv.delete(['m', key]);
      const n = meta.value ? meta.value.n : 0;
      for (let i = 0; i < n; i++) await kv.delete(['c', key, i]);
    },
  };
}

// ── Запуск на Vercel ───────────────────────────────────────────────────
export const config = { runtime: 'edge' };

// Хранилище — Upstash Redis через его REST-адрес (переменные появляются сами,
// когда в Vercel → Storage подключена база Upstash).
function redisStore() {
  const url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;
  if (!url || !token) return null;
  const call = async (cmd) => {
    const r = await fetch(url, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(cmd) });
    const j = await r.json();
    if (j.error) throw new Error(j.error);
    return j.result;
  };
  return {
    get: (key) => call(['GET', key]),
    put: (key, value, opts) => call(opts && opts.expirationTtl ? ['SET', key, String(value), 'EX', String(opts.expirationTtl)] : ['SET', key, String(value)]),
    delete: (key) => call(['DEL', key]),
  };
}

export default async function handler(request) {
  // vercel.json присылает сюда любой адрес как ?__p=/путь — восстанавливаем исходный.
  const u = new URL(request.url);
  const p = u.searchParams.get('__p');
  if (p !== null) {
    u.pathname = p.startsWith('/') ? p : '/' + p;
    u.searchParams.delete('__p');
    request = new Request(u.toString(), request);
  }
  return app.fetch(request, { SESSION_SECRET: process.env.SESSION_SECRET || '', DATA: redisStore() });
}
