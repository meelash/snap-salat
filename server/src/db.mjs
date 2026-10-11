// SQLite storage (Node's built-in node:sqlite; no dependencies).

import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  username TEXT NOT NULL UNIQUE COLLATE NOCASE,
  name TEXT NOT NULL,
  contact TEXT,
  note TEXT,
  password_hash TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'revoked')),
  created_at TEXT NOT NULL,
  decided_at TEXT,
  decided_by TEXT
);
CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS admins (
  id INTEGER PRIMARY KEY,
  username TEXT NOT NULL UNIQUE COLLATE NOCASE,
  password_hash TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS admin_sessions (
  token_hash TEXT PRIMARY KEY,
  admin_id INTEGER NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
  csrf TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS submissions (
  id INTEGER PRIMARY KEY,
  user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  user_name TEXT,
  received_at TEXT NOT NULL,
  captured_at TEXT NOT NULL,
  captured_at_ms INTEGER NOT NULL,
  captured_at_source TEXT,
  date TEXT,
  iqamah TEXT NOT NULL,
  adhan TEXT NOT NULL,
  display_clock TEXT,
  recognition TEXT,
  client TEXT,
  image_sha256 TEXT,
  photo_file TEXT,
  photo_lat REAL,
  photo_lng REAL
);
CREATE TABLE IF NOT EXISTS announcements (
  id INTEGER PRIMARY KEY,
  submission_id INTEGER REFERENCES submissions(id) ON DELETE SET NULL,
  created_at TEXT NOT NULL,
  captured_at_ms INTEGER NOT NULL,
  effective_date TEXT NOT NULL,
  changes TEXT NOT NULL,
  request TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('sending', 'sent', 'failed')),
  remote_id TEXT,
  error TEXT
);
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS current_times (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  iqamah TEXT NOT NULL,
  adhan TEXT NOT NULL,
  captured_at TEXT,
  captured_at_ms INTEGER,
  updated_at TEXT,
  submission_id INTEGER
);
`;

/** Defaults for every setting the admin page can change. */
export const DEFAULT_SETTINGS = {
  masjid_name: 'Our Masjid',
  timezone: 'UTC',
  latitude: '',
  longitude: '',
  maghrib_mode: 'board', // 'board' | 'sunset'
  maghrib_offset: '0', // minutes after sunset
  maghrib_round: 'none', // 'none' | 'up5'
  max_age_minutes: '1440',
  allow_registration: '1',
  accept_image: '1',
  widget_theme: 'dark', // 'dark' | 'light'
  widget_accent: '#D4AF5F',
  widget_show_adhan: '0',
  // Draft an announcement in an external announcement list when times change.
  announce_enabled: '0',
  announce_url: '', // e.g. http://localhost:3000
  announce_token: '', // bearer token; never shown back on the admin page
  announce_submit: '1', // '1': submit for approval; '0': leave as a draft
  // Review flags on updates.
  flag_distance_m: '500', // photo taken farther than this from the masjid
  flag_clock_minutes: '15', // board clock disagrees with the photo time by more
};

/** Columns added after the first release; created on older databases. */
const MIGRATIONS = [
  ['submissions', 'photo_lat', 'REAL'],
  ['submissions', 'photo_lng', 'REAL'],
];

export function openDb(file) {
  if (file !== ':memory:') mkdirSync(dirname(file), { recursive: true });
  const db = new DatabaseSync(file);
  db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;');
  db.exec(SCHEMA);
  for (const [table, column, type] of MIGRATIONS) {
    const has = db.prepare(`PRAGMA table_info(${table})`).all().some((c) => c.name === column);
    if (!has) db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`);
  }
  return new Store(db);
}

const now = () => new Date().toISOString();

export class Store {
  constructor(db) {
    this.db = db;
  }

  // --- settings
  settings() {
    const s = { ...DEFAULT_SETTINGS };
    for (const row of this.db.prepare('SELECT key, value FROM settings').all()) s[row.key] = row.value;
    return s;
  }
  saveSettings(values) {
    const put = this.db.prepare('INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value');
    for (const [k, v] of Object.entries(values)) {
      if (k in DEFAULT_SETTINGS) put.run(k, String(v));
    }
  }

  // --- users
  createUser({ username, name, contact, note, passwordHash }) {
    const r = this.db
      .prepare('INSERT INTO users(username, name, contact, note, password_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)')
      .run(username, name, contact ?? null, note ?? null, passwordHash, now());
    return Number(r.lastInsertRowid);
  }
  userByName(username) {
    return this.db.prepare('SELECT * FROM users WHERE username = ?').get(username);
  }
  userById(id) {
    return this.db.prepare('SELECT * FROM users WHERE id = ?').get(id);
  }
  users() {
    return this.db.prepare('SELECT * FROM users ORDER BY status, created_at DESC').all();
  }
  setUserStatus(id, status, by) {
    this.db.prepare('UPDATE users SET status = ?, decided_at = ?, decided_by = ? WHERE id = ?').run(status, now(), by, id);
    if (status !== 'approved') this.db.prepare('DELETE FROM sessions WHERE user_id = ?').run(id);
  }
  deleteUser(id) {
    this.db.prepare('DELETE FROM users WHERE id = ?').run(id);
  }

  // --- API sessions (bearer tokens, stored hashed)
  addSession(tokenHash, userId, expiresAt) {
    this.db.prepare('INSERT INTO sessions(token_hash, user_id, expires_at) VALUES (?, ?, ?)').run(tokenHash, userId, expiresAt);
  }
  sessionUser(tokenHash) {
    return this.db
      .prepare('SELECT users.* FROM sessions JOIN users ON users.id = sessions.user_id WHERE token_hash = ? AND expires_at > ?')
      .get(tokenHash, Date.now());
  }

  // --- admins
  createAdmin(username, passwordHash) {
    this.db
      .prepare('INSERT INTO admins(username, password_hash) VALUES (?, ?) ON CONFLICT(username) DO UPDATE SET password_hash = excluded.password_hash')
      .run(username, passwordHash);
  }
  adminByName(username) {
    return this.db.prepare('SELECT * FROM admins WHERE username = ?').get(username);
  }
  hasAdmins() {
    return this.db.prepare('SELECT COUNT(*) AS n FROM admins').get().n > 0;
  }
  addAdminSession(tokenHash, adminId, csrf, expiresAt) {
    this.db.prepare('INSERT INTO admin_sessions(token_hash, admin_id, csrf, expires_at) VALUES (?, ?, ?, ?)').run(tokenHash, adminId, csrf, expiresAt);
  }
  adminSession(tokenHash) {
    return this.db
      .prepare('SELECT admins.username, admin_sessions.csrf FROM admin_sessions JOIN admins ON admins.id = admin_sessions.admin_id WHERE token_hash = ? AND expires_at > ?')
      .get(tokenHash, Date.now());
  }
  deleteAdminSession(tokenHash) {
    this.db.prepare('DELETE FROM admin_sessions WHERE token_hash = ?').run(tokenHash);
  }

  // --- submissions and current times
  current() {
    const row = this.db.prepare('SELECT * FROM current_times WHERE id = 1').get();
    if (!row) return null;
    return { ...row, iqamah: JSON.parse(row.iqamah), adhan: JSON.parse(row.adhan) };
  }
  /** Records a submission and merges its times over the current ones. */
  addSubmission(s) {
    const r = this.db
      .prepare(`INSERT INTO submissions(user_id, user_name, received_at, captured_at, captured_at_ms, captured_at_source,
        date, iqamah, adhan, display_clock, recognition, client, image_sha256, photo_file, photo_lat, photo_lng)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(
        s.userId, s.userName, now(), s.capturedAt, s.capturedAtMs, s.capturedAtSource ?? null, s.date ?? null,
        JSON.stringify(s.iqamah), JSON.stringify(s.adhan), s.displayClock ?? null,
        JSON.stringify(s.recognition ?? null), JSON.stringify(s.client ?? null), s.imageSha256 ?? null, s.photoFile ?? null,
        s.location?.lat ?? null, s.location?.lng ?? null,
      );
    const id = Number(r.lastInsertRowid);
    const prev = this.current();
    this.db
      .prepare(`INSERT INTO current_times(id, iqamah, adhan, captured_at, captured_at_ms, updated_at, submission_id)
        VALUES (1, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET iqamah = excluded.iqamah, adhan = excluded.adhan,
        captured_at = excluded.captured_at, captured_at_ms = excluded.captured_at_ms, updated_at = excluded.updated_at,
        submission_id = excluded.submission_id`)
      .run(
        JSON.stringify({ ...(prev?.iqamah ?? {}), ...s.iqamah }),
        JSON.stringify({ ...(prev?.adhan ?? {}), ...s.adhan }),
        s.capturedAt, s.capturedAtMs, now(), id,
      );
    return id;
  }
  submissions(limit = 50) {
    return this.db.prepare('SELECT * FROM submissions ORDER BY id DESC LIMIT ?').all(limit).map((r) => ({
      ...r,
      iqamah: JSON.parse(r.iqamah),
      adhan: JSON.parse(r.adhan),
      recognition: JSON.parse(r.recognition),
    }));
  }
  // --- announcements
  lastAnnouncement() {
    return this.db.prepare("SELECT * FROM announcements WHERE status != 'failed' ORDER BY captured_at_ms DESC LIMIT 1").get();
  }
  addAnnouncement(a) {
    const r = this.db
      .prepare(`INSERT INTO announcements(submission_id, created_at, captured_at_ms, effective_date, changes, request,
        idempotency_key, status) VALUES (?, ?, ?, ?, ?, ?, ?, 'sending')`)
      .run(a.submissionId, now(), a.capturedAtMs, a.effectiveDate, JSON.stringify(a.changes),
        JSON.stringify(a.request), a.idempotencyKey);
    return Number(r.lastInsertRowid);
  }
  finishAnnouncement(id, { status, remoteId = null, error = null }) {
    this.db.prepare('UPDATE announcements SET status = ?, remote_id = ?, error = ? WHERE id = ?').run(status, remoteId, error, id);
  }
  announcement(id) {
    const r = this.db.prepare('SELECT * FROM announcements WHERE id = ?').get(id);
    return r && { ...r, changes: JSON.parse(r.changes), request: JSON.parse(r.request) };
  }
  announcements(limit = 20) {
    return this.db.prepare('SELECT * FROM announcements ORDER BY id DESC LIMIT ?').all(limit)
      .map((r) => ({ ...r, changes: JSON.parse(r.changes), request: JSON.parse(r.request) }));
  }

  submission(id) {
    return this.db.prepare('SELECT * FROM submissions WHERE id = ?').get(id);
  }
}
