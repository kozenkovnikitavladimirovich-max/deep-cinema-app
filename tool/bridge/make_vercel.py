"""Собрать мост для Vercel (tool/bridge/vercel) из worker.js.

Vercel: Edge Function api/index.js; хранилище — Upstash Redis (бесплатно, подключается
в Vercel → Storage). Все адреса перенаправляются на функцию (vercel.json)."""
import json
import os

here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, 'worker.js'), encoding='utf-8').read()
assert 'export default {' in src
body = src.replace('export default {', 'const app = {', 1)
adapter = r'''
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
'''
out_dir = os.path.join(here, 'vercel')
os.makedirs(os.path.join(out_dir, 'api'), exist_ok=True)
open(os.path.join(out_dir, 'api', 'index.js'), 'w', encoding='utf-8').write(
    '// Deep Cinema — мост для Vercel. Сгенерирован из ../../worker.js (tool/bridge/make_vercel.py).\n\n' + body + adapter)
json.dump({'rewrites': [{'source': '/(.*)', 'destination': '/api?__p=/$1'}]}, open(os.path.join(out_dir, 'vercel.json'), 'w'), indent=2)
json.dump({'name': 'deep-cinema-bridge', 'private': True, 'type': 'module'}, open(os.path.join(out_dir, 'package.json'), 'w'), indent=2)
print('vercel/ готов')
