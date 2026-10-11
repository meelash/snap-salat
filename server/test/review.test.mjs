// node --test server/test/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { openDb } from '../src/db.mjs';
import { reviewNotes, distanceMetres } from '../src/review.mjs';

const settings = {
  latitude: '41.34291', longitude: '-72.92657', timezone: 'America/New_York',
  flag_distance_m: '500', flag_clock_minutes: '15',
};
// 16:53 in New York on 2026-10-09.
const capturedAtMs = Date.parse('2026-10-09T16:53:38-04:00');

test('distance is right', () => {
  // About 6.4 km between these two points in Hamden.
  assert.ok(Math.abs(distanceMetres(41.3962, -72.8973, 41.34291, -72.92657) - 6409) < 20);
});

test('a photo taken at the masjid with a matching board clock passes', () => {
  const notes = reviewNotes({ photo_lat: 41.3431, photo_lng: -72.9263, display_clock: '16:54', captured_at_ms: capturedAtMs, captured_at_source: 'exif' }, settings);
  assert.deepEqual(notes.filter((n) => n.level === 'flag'), []);
  assert.match(notes[0].text, /Taken at the masjid/);
});

test('a photo taken far away is flagged', () => {
  const notes = reviewNotes({ photo_lat: 41.3962, photo_lng: -72.8973, captured_at_ms: capturedAtMs }, settings);
  assert.equal(notes[0].level, 'flag');
  assert.match(notes[0].text, /Taken 6\.4 km from the masjid/);
});

test('a board clock that disagrees with the photo time is flagged (12-hour aware)', () => {
  const off = reviewNotes({ display_clock: '15:10', captured_at_ms: capturedAtMs }, settings);
  assert.ok(off.some((n) => n.level === 'flag' && /Board clock showed 3:10 PM, but the photo is from 4:53 PM/.test(n.text)));
  // The board's clock is 12-hour: 04:53 and 16:53 look the same on it.
  const same = reviewNotes({ display_clock: '04:53', captured_at_ms: capturedAtMs }, settings);
  assert.ok(!same.some((n) => /Board clock/.test(n.text)));
});

test('missing location is a note, file-date time is a flag', () => {
  const notes = reviewNotes({ captured_at_ms: capturedAtMs, captured_at_source: 'file' }, settings);
  assert.deepEqual(notes.map((n) => n.level), ['note', 'flag']);
});

test('older databases gain the new columns', () => {
  const dir = mkdtempSync(join(tmpdir(), 'snap-salat-migrate-'));
  const file = join(dir, 'old.db');
  const old = new DatabaseSync(file);
  old.exec(`CREATE TABLE submissions (id INTEGER PRIMARY KEY, user_id INTEGER, user_name TEXT, received_at TEXT NOT NULL,
    captured_at TEXT NOT NULL, captured_at_ms INTEGER NOT NULL, captured_at_source TEXT, date TEXT, iqamah TEXT NOT NULL,
    adhan TEXT NOT NULL, display_clock TEXT, recognition TEXT, client TEXT, image_sha256 TEXT, photo_file TEXT)`);
  old.close();
  const store = openDb(file);
  const cols = store.db.prepare('PRAGMA table_info(submissions)').all().map((c) => c.name);
  assert.ok(cols.includes('photo_lat') && cols.includes('photo_lng'));
  rmSync(dir, { recursive: true });
});
