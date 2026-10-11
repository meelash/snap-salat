// HTTP helpers, password hashing and tokens.

import { randomBytes, scrypt, timingSafeEqual, createHash } from 'node:crypto';
import { promisify } from 'node:util';

const scryptAsync = promisify(scrypt);

export async function hashPassword(password) {
  const salt = randomBytes(16);
  const key = await scryptAsync(password, salt, 64);
  return `scrypt$${salt.toString('base64')}$${key.toString('base64')}`;
}

export async function checkPassword(password, stored) {
  const [kind, salt, key] = String(stored).split('$');
  if (kind !== 'scrypt') return false;
  const expected = Buffer.from(key, 'base64');
  const actual = await scryptAsync(password, Buffer.from(salt, 'base64'), expected.length);
  return timingSafeEqual(expected, actual);
}

/** A random token and the hash we store (never the token itself). */
export function newToken() {
  const token = randomBytes(32).toString('base64url');
  return { token, hash: hashToken(token) };
}
export const hashToken = (t) => createHash('sha256').update(String(t)).digest('hex');

export function sendJson(res, status, body, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...headers });
  res.end(body === undefined ? '' : JSON.stringify(body));
}

export const fail = (res, status, error, message, extra = {}) => sendJson(res, status, { error, message, ...extra });

export function sendHtml(res, status, html, headers = {}) {
  res.writeHead(status, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...headers,
  });
  res.end(html);
}

export function redirect(res, location, headers = {}) {
  res.writeHead(303, { Location: location, ...headers });
  res.end();
}

export async function readBody(req, limit = 1024 * 1024) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw new HttpError(413, 'too_large', 'Request too large.');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

export async function readJson(req, limit) {
  const text = await readBody(req, limit);
  try {
    return JSON.parse(text || '{}');
  } catch {
    throw new HttpError(400, 'invalid_json', 'Body must be JSON.');
  }
}

export async function readForm(req) {
  return Object.fromEntries(new URLSearchParams(await readBody(req, 64 * 1024)));
}

export class HttpError extends Error {
  constructor(status, code, message, extra) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

export function cookies(req) {
  const out = {};
  for (const part of (req.headers.cookie ?? '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

export const escapeHtml = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/** Simple fixed-window rate limiter keyed by e.g. IP address. */
export function rateLimiter(max, windowMs) {
  const hits = new Map();
  return (key) => {
    const t = Date.now();
    const recent = (hits.get(key) ?? []).filter((x) => x > t - windowMs);
    recent.push(t);
    hits.set(key, recent);
    return recent.length <= max;
  };
}

export const clientIp = (req) =>
  // Behind a reverse proxy (Caddy, nginx) the real address is forwarded.
  (req.headers['x-forwarded-for'] ?? '').split(',')[0].trim() || req.socket.remoteAddress || '?';
