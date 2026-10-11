#!/usr/bin/env node
// Validates registry/masajid/**/*.json and builds registry/index.json, the
// list the app downloads. Also copies it into the app as its offline
// fallback. No dependencies.
//
//   node tools/build-registry.mjs            validate and write the index
//   node tools/build-registry.mjs --check    validate only (used on pull requests)

import { readdirSync, readFileSync, writeFileSync, statSync, existsSync, mkdirSync } from 'node:fs';
import { join, relative, dirname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const masajidDir = join(root, 'registry', 'masajid');
const checkOnly = process.argv.includes('--check');

const PRAYERS = ['fajr', 'sunrise', 'dhuhr', 'asr', 'maghrib', 'isha', 'jumuah'];
const ORDERS = ['rtl-rows', 'ltr-rows', 'rtl-columns', 'ltr-columns'];
const KEYS = ['$schema', 'name', 'country', 'region', 'city', 'area', 'api', 'website', 'location', 'display', 'maintainers'];

export const slug = (s) =>
  s
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/['’]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');

function* walk(dir) {
  if (!existsSync(dir)) return;
  for (const name of readdirSync(dir).sort()) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* walk(p);
    else if (name.endsWith('.json')) yield p;
  }
}

export function validateEntry(entry, relPath) {
  const errors = [];
  const err = (m) => errors.push(`${relPath}: ${m}`);
  if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
    err('must be a JSON object');
    return errors;
  }
  for (const k of Object.keys(entry)) if (!KEYS.includes(k)) err(`unknown field "${k}"`);
  const missing = ['name', 'country', 'region', 'city', 'api'].filter(
    (k) => typeof entry[k] !== 'string' || !entry[k].trim(),
  );
  for (const k of missing) err(`"${k}" is required`);
  if (missing.length) return errors;
  if (!/^[A-Z]{2}$/.test(entry.country)) err('"country" must be a 2-letter ISO code like "US"');
  let api;
  try {
    api = new URL(entry.api);
  } catch {
    err('"api" is not a valid URL');
  }
  if (api && api.protocol !== 'https:') err('"api" must use https://');
  if (api && (api.search || api.hash)) err('"api" must not have ?query or #fragment');
  if (entry.area !== undefined && (typeof entry.area !== 'string' || !entry.area.trim())) {
    err('"area" must be a non-empty string when given');
  }
  if (entry.website !== undefined && !/^https?:\/\//.test(entry.website)) err('"website" must be a URL');
  if (entry.location !== undefined) {
    const { lat, lng, ...rest } = entry.location;
    if (typeof lat !== 'number' || lat < -90 || lat > 90) err('"location.lat" must be -90..90');
    if (typeof lng !== 'number' || lng < -180 || lng > 180) err('"location.lng" must be -180..180');
    if (Object.keys(rest).length) err('"location" only has lat and lng');
  }
  if (entry.display !== undefined) {
    const d = entry.display;
    for (const k of Object.keys(d)) {
      if (!['type', 'order', 'sequence', 'current_time_clock'].includes(k)) err(`unknown field "display.${k}"`);
    }
    if (d.type !== undefined && !['analog-clocks', 'text'].includes(d.type)) err('"display.type" must be analog-clocks or text');
    if (d.order !== undefined && !ORDERS.includes(d.order)) err(`"display.order" must be one of ${ORDERS.join(', ')}`);
    if (d.sequence !== undefined && !(Array.isArray(d.sequence) && d.sequence.every((p) => PRAYERS.includes(p)))) {
      err(`"display.sequence" must list prayers from ${PRAYERS.join(', ')}`);
    }
    if (d.current_time_clock !== undefined && typeof d.current_time_clock !== 'boolean') {
      err('"display.current_time_clock" must be true or false');
    }
  }
  if (entry.maintainers !== undefined &&
      !(Array.isArray(entry.maintainers) && entry.maintainers.every((m) => /^[A-Za-z0-9-]+$/.test(m)))) {
    err('"maintainers" must be a list of GitHub usernames');
  }

  // The path must match the entry, so the tree stays browsable.
  const parts = relPath.split(sep);
  const expected = [entry.country.toLowerCase(), slug(entry.region), slug(entry.city)];
  if (parts.length !== 4 || parts.slice(0, 3).join('/') !== expected.join('/')) {
    err(`should be at registry/masajid/${expected.join('/')}/<masjid>.json`);
  }
  if (!/^[a-z0-9]+(-[a-z0-9]+)*\.json$/.test(parts.at(-1))) {
    err('file name must be a lowercase slug like "masjid-al-noor.json"');
  }
  return errors;
}

export function buildIndex() {
  const errors = [];
  const masajid = [];
  const apis = new Map();
  for (const file of walk(masajidDir)) {
    const rel = relative(masajidDir, file);
    let entry;
    try {
      entry = JSON.parse(readFileSync(file, 'utf8'));
    } catch (e) {
      errors.push(`${rel}: invalid JSON (${e.message})`);
      continue;
    }
    const entryErrors = validateEntry(entry, rel);
    errors.push(...entryErrors);
    if (entryErrors.length) continue;
    const normalisedApi = entry.api.replace(/\/$/, '');
    if (apis.has(normalisedApi)) {
      errors.push(`${rel}: same api as ${apis.get(normalisedApi)}`);
    }
    apis.set(normalisedApi, rel);
    const { $schema, ...rest } = entry;
    masajid.push({ id: rel.replace(/\.json$/, '').split(sep).join('/'), ...rest, api: normalisedApi });
  }
  const key = (m) => [m.country, m.region, m.city, m.area ?? '', m.name].join('\u0000').toLowerCase();
  masajid.sort((a, b) => key(a).localeCompare(key(b)));
  return { errors, index: { version: 1, masajid } };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { errors, index } = buildIndex();
  if (errors.length) {
    console.error('Registry problems:\n' + errors.map((e) => `  - ${e}`).join('\n'));
    process.exit(1);
  }
  console.log(`${index.masajid.length} masjid entr${index.masajid.length === 1 ? 'y' : 'ies'} OK.`);
  if (!checkOnly) {
    const json = JSON.stringify(index, null, 2) + '\n';
    writeFileSync(join(root, 'registry', 'index.json'), json);
    const assets = join(root, 'app', 'assets');
    mkdirSync(assets, { recursive: true });
    writeFileSync(join(assets, 'registry.json'), json);
    console.log('Wrote registry/index.json and app/assets/registry.json');
  }
}
