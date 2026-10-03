import { createHash, randomBytes } from 'node:crypto';
import { reply, serverClient } from './_shared.mjs';
import { validateRentalRequestFields } from '../../src/lib/rental-rules.js';

const tokenHash = (token) => createHash('sha256').update(token).digest('hex');
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export default async (request) => {
  if (request.method !== 'POST') return reply(405, { error: 'Method not allowed.' }, { allow: 'POST' });

  let input;
  try {
    const body = await request.text();
    if (body.length > 8192) return reply(413, { error: 'Request is too large.' });
    input = JSON.parse(body);
  } catch {
    return reply(400, { error: 'Invalid request.' });
  }

  const db = serverClient();
  if (input?.action === 'create') {
    const accountId = String(input.account_id || '');
    const nickname = String(input.nickname || '').trim();
    const telegram = String(input.telegram_username || '').trim();
    const hours = Number(input.duration_hours);
    const validationError = validateRentalRequestFields({ accountId, nickname, telegramUsername: telegram, durationHours: hours });
    if (validationError) return reply(400, { error: validationError });

    const token = randomBytes(32).toString('base64url');
    const { data, error } = await db.rpc('create_manual_rental_request', {
      p_account_id: accountId,
      p_duration_hours: hours,
      p_customer_name: nickname,
      p_customer_telegram: telegram || null,
      p_access_token_hash: tokenHash(token),
    });
    if (error) return reply(400, { error: error.message || 'Could not submit this rental request.' });
    const created = data?.[0];
    if (!created?.request_id) return reply(500, { error: 'The request was not saved. Please try again.' });
    return reply(201, {
      request_id: created.request_id,
      token,
      game_name: created.game_name,
      account_title: created.account_title,
      duration_hours: hours,
      hourly_rate: created.hourly_rate,
      total_price: created.total_price,
      status: 'pending',
    });
  }

  if (input?.action === 'status') {
    const requestId = String(input.request_id || '');
    const token = String(input.token || '');
    if (!uuidPattern.test(requestId) || token.length < 40 || token.length > 64) return reply(404, { error: 'Rental request not found.' });
    const { data, error } = await db.from('manual_rental_requests')
      .select('id,game_name,account_title,duration_hours,hourly_rate,total_price,status,created_at,started_at,expires_at')
      .eq('id', requestId).eq('access_token_hash', tokenHash(token)).maybeSingle();
    if (error || !data) return reply(404, { error: 'Rental request not found.' });
    return reply(200, { ...data, server_now: new Date().toISOString() });
  }

  return reply(400, { error: 'Unknown rental request action.' });
};
