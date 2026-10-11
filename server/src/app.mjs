// Routes everything: the Snap Salat API under /snap-salat, the public JSON
// and widget, and the admin pages.

import { createServer } from 'node:http';
import { apiRoutes } from './api.mjs';
import { publicRoutes } from './public.mjs';
import { adminRoutes } from './admin.mjs';
import { announcer } from './announce.mjs';
import { HttpError, fail, sendHtml, redirect, escapeHtml } from './util.mjs';

export const API_BASE = '/snap-salat';

export function createApp({ store, dataDir, secureCookies = true, log = () => {}, limits, fetchImpl }) {
  // Background work (announcements) still running; tests can await it.
  const pending = new Set();
  const track = (p) => {
    pending.add(p);
    p.finally(() => pending.delete(p));
    return p;
  };
  const announce = announcer({ store, log, fetchImpl });
  const api = apiRoutes({ store, dataDir, log, limits, announce, track });
  const pub = publicRoutes({ store });
  const admin = adminRoutes({ store, dataDir, secureCookies, log, announce });

  async function handle(req, res) {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname.replace(/\/+$/, '') || '/';
    // HEAD is GET without the body (Node drops the body for HEAD itself).
    const method = req.method === 'HEAD' ? 'GET' : req.method;
    const key = `${method} ${path}`;

    if (path === API_BASE || path.startsWith(`${API_BASE}/`)) {
      const sub = path.slice(API_BASE.length) || '/';
      const handler = api[`${method} ${sub}`];
      if (req.method === 'OPTIONS' && sub === '/prayer-times') {
        res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET' });
        return res.end();
      }
      if (!handler) return fail(res, 404, 'not_found', 'Not found');
      return handler(req, res, url);
    }
    if (pub[key]) return pub[key](req, res, url);
    if (admin.exact[key]) return admin.exact[key](req, res, url);
    for (const [pattern, handler] of admin.patterns) {
      const m = pattern.exec(key);
      if (m) return handler(req, res, url, m.groups);
    }
    if (key === 'GET /healthz') return fail(res, 200, 'ok', 'ok');
    if (key === 'GET /') return redirect(res, '/widget');
    return sendHtml(res, 404, '<!doctype html><title>Not found</title><p>Not found.</p>');
  }

  const server = createServer((req, res) => {
    // Admin pages must not be framed by other sites.
    if (req.url.startsWith('/admin')) {
      res.setHeader('X-Frame-Options', 'DENY');
      res.setHeader('Referrer-Policy', 'same-origin');
    }
    handle(req, res).catch((err) => {
      if (res.headersSent) return res.end();
      const status = err instanceof HttpError ? err.status : 500;
      if (status === 500) console.error(err);
      if (req.url.startsWith('/admin')) {
        return sendHtml(res, status, `<!doctype html><meta name="viewport" content="width=device-width">
          <p>${escapeHtml(err instanceof HttpError ? err.message : 'Something went wrong.')}</p><p><a href="/admin">Back</a></p>`);
      }
      fail(res, status, err instanceof HttpError ? err.code : 'server_error',
        err instanceof HttpError ? err.message : 'Something went wrong.', err.extra);
    });
  });
  server.idle = () => Promise.all([...pending]);
  return server;
}
