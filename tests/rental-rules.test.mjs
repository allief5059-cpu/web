import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { MAX_RENTAL_HOURS, rentalQuote, validateRentalRequestFields } from '../src/lib/rental-rules.js';

process.env.VITE_SUPABASE_URL ||= 'https://unit-test.supabase.co';
process.env.SUPABASE_SERVICE_ROLE_KEY ||= 'unit-test-only-placeholder';
const { default: rentalRequests } = await import('../netlify/functions/rental-requests.mjs');

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const validRequest = { accountId: '3e28ec36-b1df-4dd6-ae87-1313ba2ab166', nickname: 'Player1', durationHours: 2 };

test('a guest can request the minimum rental without a Telegram username', () => {
  assert.equal(validateRentalRequestFields({ ...validRequest, durationHours: 1 }), null);
});

test('nickname and optional Telegram username are trimmed and accepted', () => {
  assert.equal(validateRentalRequestFields({ ...validRequest, nickname: '  Player1  ', telegramUsername: ' @Player_1 ' }), null);
});

test('rental length accepts the maximum and rejects values outside 1–168 hours', () => {
  assert.equal(validateRentalRequestFields({ ...validRequest, durationHours: MAX_RENTAL_HOURS }), null);
  assert.match(validateRentalRequestFields({ ...validRequest, durationHours: 0 }), /1 and 168/);
  assert.match(validateRentalRequestFields({ ...validRequest, durationHours: 169 }), /1 and 168/);
  assert.match(validateRentalRequestFields({ ...validRequest, durationHours: 1.5 }), /1 and 168/);
});

test('rental requests require a valid listing and a nickname', () => {
  assert.match(validateRentalRequestFields({ ...validRequest, accountId: 'bad-id' }), /available listing/);
  assert.match(validateRentalRequestFields({ ...validRequest, nickname: '   ' }), /nickname/);
  assert.match(validateRentalRequestFields({ ...validRequest, nickname: 'x'.repeat(101) }), /nickname/);
});

test('an invalid optional Telegram username is rejected without requiring one', () => {
  assert.equal(validateRentalRequestFields({ ...validRequest, telegramUsername: '' }), null);
  assert.match(validateRentalRequestFields({ ...validRequest, telegramUsername: 'bad handle' }), /Telegram username/);
});

test('hourly quote rounds to cents and refuses invalid inputs', () => {
  assert.equal(rentalQuote(1.25, 3), 3.75);
  assert.equal(rentalQuote(0.1, 3), 0.3);
  assert.equal(rentalQuote(0, 3), null);
  assert.equal(rentalQuote(2, 169), null);
});

test('rental API rejects unsupported methods without contacting Supabase', async () => {
  const response = await rentalRequests(new Request('https://store.example/api/rental-requests', { method: 'GET' }));
  assert.equal(response.status, 405);
});

test('rental API rejects malformed guest requests before database access', async () => {
  const response = await rentalRequests(new Request('https://store.example/api/rental-requests', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ action: 'create', account_id: 'bad-id', nickname: 'Player', duration_hours: 2 }),
  }));
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /available listing/);
});

test('rental API does not reveal status without a valid private token shape', async () => {
  const response = await rentalRequests(new Request('https://store.example/api/rental-requests', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ action: 'status', request_id: validRequest.accountId, token: 'not-a-token' }),
  }));
  assert.equal(response.status, 404);
});

test('frontend no longer asks for credentials or starts the payment checkout', async () => {
  const app = await readFile(resolve(root, 'src/App.jsx'), 'utf8');
  assert.doesNotMatch(app, /Account credentials|credential_payload|\/api\/create-checkout|Billplz/);
});

test('migration removes credential storage and starts the timer only at approval', async () => {
  const migration = await readFile(resolve(root, 'supabase/migrations/202610020002_manual_contact_rentals.sql'), 'utf8');
  assert.match(migration, /drop column if exists credential_payload/);
  assert.match(migration, /revoke all on public\.manual_rental_requests from anon, authenticated/);
  assert.match(migration, /set status = 'approved', started_at = now\(\),\s*expires_at = now\(\) \+ make_interval\(hours => v_request\.duration_hours\)/);
});
