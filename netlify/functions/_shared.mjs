import { createClient } from '@supabase/supabase-js';

export function reply(statusCode, payload, headers = {}) {
  return new Response(JSON.stringify(payload), { status: statusCode, headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers } });
}

export function serverClient() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error('Marketplace server configuration is incomplete.');
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

export function userClient(token) {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_ANON_KEY;
  if (!url || !key) throw new Error('Marketplace public server configuration is incomplete.');
  return createClient(url, key, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false, autoRefreshToken: false } });
}

export function getBearer(request) { return request.headers.get('authorization')?.match(/^Bearer (.+)$/i)?.[1] || null; }
