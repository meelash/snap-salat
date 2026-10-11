// node --test tools/build-registry.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateEntry, slug, buildIndex } from './build-registry.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const example = JSON.parse(readFileSync(join(root, 'registry', 'example-entry.json'), 'utf8'));
const path = join('us', 'connecticut', 'hamden', 'example-masjid.json');

test('the documented example is valid', () => {
  assert.deepEqual(validateEntry(example, path), []);
});

test('slugs', () => {
  assert.equal(slug('Masjid Al-Noor'), 'masjid-al-noor');
  assert.equal(slug('Québec'), 'quebec');
  assert.equal(slug("Ka'bah St."), 'kabah-st');
});

test('rejects http, unknown fields and wrong paths', () => {
  const errors = validateEntry({ ...example, api: 'http://example.org', colour: 'green' },
    join('us', 'new-york', 'hamden', 'x.json'));
  assert.ok(errors.some((e) => e.includes('https')));
  assert.ok(errors.some((e) => e.includes('unknown field "colour"')));
  assert.ok(errors.some((e) => e.includes('us/connecticut/hamden')));
});

test('the committed registry is valid', () => {
  assert.deepEqual(buildIndex().errors, []);
});
