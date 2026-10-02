import { getBearer, reply, serverClient, userClient } from './_shared.mjs';

export default async (request) => {
  if (request.method !== 'POST') return reply(405, { error: 'Method not allowed.' }, { allow: 'POST' });
  const token = getBearer(request);
  if (!token) return reply(401, { error: 'Sign in before checkout.' });
  const required = ['BILLPLZ_API_KEY', 'BILLPLZ_COLLECTION_ID', 'BILLPLZ_X_SIGNATURE_KEY', 'PUBLIC_SITE_URL'];
  if (required.some((key) => !process.env[key])) return reply(503, { error: 'Payments are not configured for this store yet.' });
  let input;
  try { input = await request.json(); } catch { return reply(400, { error: 'Invalid request.' }); }
  if (!input?.account_id || !['buy', 'rent'].includes(input.kind)) return reply(400, { error: 'Choose an account and order type.' });

  const db = serverClient();
  const userDb = userClient(token);
  const { data: authData, error: authError } = await db.auth.getUser(token);
  if (authError || !authData?.user) return reply(401, { error: 'Your session has expired. Sign in again.' });
  const { data: reserved, error: reserveError } = await userDb.rpc('reserve_checkout', {
    p_account_id: input.account_id,
    p_kind: input.kind,
    p_rental_plan_id: input.kind === 'rent' ? input.rental_plan_id : null,
  });
  const order = reserved?.[0];
  if (reserveError || !order) return reply(409, { error: reserveError?.message || 'This account is not available.' });

  const amount = Math.round(Number(order.amount) * 100);
  const siteUrl = process.env.PUBLIC_SITE_URL.replace(/\/$/, '');
  const form = new URLSearchParams({
    collection_id: process.env.BILLPLZ_COLLECTION_ID,
    email: authData.user.email,
    name: authData.user.user_metadata?.name || authData.user.email,
    amount: String(amount),
    description: `ARTZZY STORE ${input.kind.toUpperCase()} ${order.order_id}`,
    callback_url: `${siteUrl}/.netlify/functions/billplz-callback`,
    redirect_url: `${siteUrl}/payment-result?order=${order.order_id}`,
    reference_1_label: 'Artzzy order',
    reference_1: order.order_id,
  });
  const base = (process.env.BILLPLZ_BASE_URL || 'https://www.billplz.com').replace(/\/$/, '');
  const providerResponse = await fetch(`${base}/api/v3/bills`, {
    method: 'POST',
    headers: { authorization: `Basic ${Buffer.from(`${process.env.BILLPLZ_API_KEY}:`).toString('base64')}`, 'content-type': 'application/x-www-form-urlencoded' },
    body: form,
  });
  const bill = await providerResponse.json().catch(() => ({}));
  let paymentUrl;
  try { paymentUrl = new URL(bill.url); } catch { paymentUrl = null; }
  const host = paymentUrl?.hostname || '';
  const trustedBillplzHost = host === 'billplz.com' || host.endsWith('.billplz.com') || host === 'billplz-sandbox.com' || host.endsWith('.billplz-sandbox.com');
  if (!providerResponse.ok || !bill.id || !paymentUrl || paymentUrl.protocol !== 'https:' || !trustedBillplzHost) {
    await db.rpc('apply_checkout_creation_failure', { p_order_id: order.order_id });
    return reply(502, { error: 'The payment provider could not create a bill. Please try again.' });
  }
  const { error: attachError } = await userDb.rpc('attach_billplz_bill', { p_order_id: order.order_id, p_bill_id: bill.id });
  if (attachError) return reply(502, { error: 'Payment setup did not finish. Contact support before trying again.' });
  return reply(200, { payment_url: paymentUrl.toString(), order_id: order.order_id });
};
