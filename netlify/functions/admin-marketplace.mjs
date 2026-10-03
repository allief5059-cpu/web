import { getBearer, reply, serverClient } from './_shared.mjs';

const bad = (msg) => ({ error: msg });

function gameSlugBase(name) {
  const normalized = String(name || '').trim().toLowerCase();
  const compact = normalized.replace(/[^a-z0-9]/g, '');
  if (compact === 'pubg') return 'Pubg';
  if (compact === 'efootball' || compact === 'pes') return 'Pes';
  return normalized.split(/[^a-z0-9]+/).filter(Boolean)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1)).join('_');
}

export default async (request) => {
  const token = getBearer(request);
  if (!token) return reply(401, bad('Sign in as an administrator.'));
  const db = serverClient();
  const { data: auth, error: authError } = await db.auth.getUser(token);
  if (authError || !auth.user) return reply(401, bad('Your session has expired.'));
  const { data: profile } = await db.from('profiles').select('role').eq('id', auth.user.id).maybeSingle();
  if (profile?.role !== 'admin') return reply(403, bad('Administrator access required.'));

  if (request.method === 'GET') {
    const [games, accounts, orders, payments, rentals, customers, rentalRequests] = await Promise.all([
      db.from('games').select('id,name,slug,description,cover_image_url,is_active,sort_order').order('name'),
      db.from('accounts').select('id,game_id,title,description,features,cover_image_url,buy_price,rent_hourly_price,status,created_at').order('created_at', { ascending: false }),
      db.from('orders').select('id,customer_id,account_id,kind,amount,status,paid_at,created_at,rental_plan_id').order('created_at', { ascending: false }).limit(100),
      db.from('payments').select('order_id,provider_bill_id,amount,status,provider_paid_at').limit(100),
      db.from('rentals').select('id,order_id,account_id,customer_id,started_at,expires_at,status').order('expires_at', { ascending: false }).limit(100),
      db.auth.admin.listUsers({ page: 1, perPage: 100 }),
      db.from('manual_rental_requests').select('id,account_id,game_name,account_title,customer_name,customer_telegram,duration_hours,hourly_rate,total_price,status,created_at,started_at,expires_at').order('created_at', { ascending: false }).limit(100),
    ]);
    if ([games, accounts, orders, payments, rentals, rentalRequests].some((r) => r.error)) return reply(500, bad('Could not load admin data.'));
    const [plans, profiles] = await Promise.all([
      db.from('rental_plans').select('id,account_id,label,duration_days,price,is_active').order('duration_days'),
      db.from('profiles').select('id,display_name,role,created_at'),
    ]);
    return reply(200, { games: games.data, accounts: accounts.data, plans: plans.data || [], orders: orders.data,
      payments: payments.data, rentals: rentals.data, rental_requests: rentalRequests.data || [], customers: (customers.data?.users || []).map((u) => ({ id: u.id, email: u.email, created_at: u.created_at,
        display_name: profiles.data?.find((p) => p.id === u.id)?.display_name || '', role: profiles.data?.find((p) => p.id === u.id)?.role || 'customer' })) });
  }
  if (request.method !== 'POST') return reply(405, bad('Method not allowed.'), { allow: 'GET, POST' });
  let input;
  try { input = await request.json(); } catch { return reply(400, bad('Invalid request.')); }
  const { action, data = {} } = input || {};
  let error;
  let auditedEntityId = data.id || null;
  if (action === 'save-game') {
    const row = { name: String(data.name || '').trim(), description: data.description || '', cover_image_url: data.cover_image_url || null, is_active: data.is_active !== false };
    if (!row.name) return reply(400, bad('Add a game name.'));
    if (data.id) {
      const result = await db.from('games').update(row).eq('id', data.id).select('id').single();
      error = result.error;
      auditedEntityId = result.data?.id || auditedEntityId;
    } else {
      const base = gameSlugBase(row.name);
      if (!base) return reply(400, bad('Enter a game name containing letters or numbers.'));
      const { data: existing, error: lookupError } = await db.from('games').select('slug');
      if (lookupError) return reply(500, bad('Could not generate a game slug.'));
      const prefix = `${base}_`;
      const largest = (existing || []).reduce((max, item) => {
        if (!item.slug?.startsWith(prefix)) return max;
        const number = Number(item.slug.slice(prefix.length));
        return Number.isInteger(number) && number > max ? number : max;
      }, 0);
      const result = await db.from('games').insert({ ...row, slug: `${prefix}${largest + 1}` }).select('id').single();
      error = result.error;
      auditedEntityId = result.data?.id || auditedEntityId;
    }
  } else if (action === 'delete-game') {
    ({ error } = await db.from('games').delete().eq('id', data.id));
  } else if (action === 'save-account') {
    const buy = data.buy_price === '' || data.buy_price == null ? null : Number(data.buy_price);
    const hourly = data.rent_hourly_price === '' || data.rent_hourly_price == null ? null : Number(data.rent_hourly_price);
    if (!data.game_id || !String(data.title || '').trim() || (buy != null && (!Number.isFinite(buy) || buy < 0)) || (hourly != null && (!Number.isFinite(hourly) || hourly <= 0))) return reply(400, bad('Check the game, title and prices. Hourly rent must be greater than zero.'));
    if (!(buy > 0) && !(hourly > 0)) return reply(400, bad('Set a buy price or an hourly rental price.'));
    const row = { game_id: data.game_id, title: String(data.title).trim(), description: data.description || '', features: String(data.features || '').split(',').map((v) => v.trim()).filter(Boolean), cover_image_url: data.cover_image_url || null, buy_price: buy, rent_hourly_price: hourly, status: data.status || 'available' };
    if (!['available', 'disabled'].includes(row.status) && !data.id) return reply(400, bad('New accounts can only start as available or disabled.'));
    let result = data.id ? await db.from('accounts').update(row).eq('id', data.id).select('id').single() : await db.from('accounts').insert(row).select('id').single();
    error = result.error;
    auditedEntityId = result.data?.id || auditedEntityId;
  } else if (action === 'delete-account') {
    ({ error } = await db.from('accounts').delete().eq('id', data.id));
  } else if (action === 'set-account-status') {
    if (!['available', 'disabled'].includes(data.status)) return reply(400, bad('Use disable or make available for manual status changes.'));
    ({ error } = await db.from('accounts').update({ status: data.status, updated_at: new Date().toISOString() }).eq('id', data.id));
  } else if (action === 'extend-rental') {
    const days = Number(data.days);
    if (!Number.isInteger(days) || days < 1 || days > 365) return reply(400, bad('Enter an extension from 1 to 365 days.'));
    ({ error } = await db.rpc('admin_extend_rental', { p_rental_id: data.id, p_days: days }));
  } else if (action === 'end-rental') {
    ({ error } = await db.rpc('admin_end_rental', { p_rental_id: data.id }));
  } else if (action === 'approve-rental-request') {
    ({ error } = await db.rpc('approve_manual_rental_request', { p_request_id: data.id }));
  } else if (action === 'reject-rental-request') {
    ({ error } = await db.rpc('reject_manual_rental_request', { p_request_id: data.id }));
  } else {
    return reply(400, bad('Unknown admin action.'));
  }
  if (error) return reply(400, bad(error.message || 'Could not save this change.'));
  await db.from('admin_audit_log').insert({ admin_id: auth.user.id, action, entity_type: action.includes('game') ? 'game' : action.includes('rental') ? 'rental' : 'account', entity_id: auditedEntityId, details: action === 'save-account' ? { title: data.title, status: data.status || 'available' } : {} });
  return reply(200, { ok: true });
};
