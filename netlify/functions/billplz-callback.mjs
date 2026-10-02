import { createHmac, timingSafeEqual } from 'node:crypto';
import { reply, serverClient } from './_shared.mjs';

function verifySignature(values, secret) {
  const received = values.get('x_signature');
  if (!received) return false;
  const source = [...values.entries()]
    .filter(([key]) => key.toLowerCase() !== 'x_signature')
    .sort(([a], [b]) => a.toLowerCase().localeCompare(b.toLowerCase()))
    .map(([key, value]) => `${key}${value}`)
    .join('|');
  const expected = createHmac('sha256', secret).update(source).digest('hex');
  const left = Buffer.from(received.toLowerCase(), 'hex');
  const right = Buffer.from(expected, 'hex');
  return left.length === right.length && timingSafeEqual(left, right);
}

export default async (request) => {
  if (request.method !== 'POST') return reply(405, { error: 'Method not allowed.' }, { allow: 'POST' });
  if (!process.env.BILLPLZ_X_SIGNATURE_KEY || !process.env.BILLPLZ_COLLECTION_ID) return reply(503, { error: 'Payment callback is not configured.' });
  const values = new URLSearchParams(await request.text());
  if (!verifySignature(values, process.env.BILLPLZ_X_SIGNATURE_KEY)) return reply(400, { error: 'Invalid provider signature.' });
  const billId = values.get('id');
  const collectionId = values.get('collection_id');
  const cents = Number(values.get('amount'));
  const paid = values.get('paid') === 'true' && values.get('state') === 'paid';
  if (!billId || collectionId !== process.env.BILLPLZ_COLLECTION_ID || !Number.isSafeInteger(cents) || cents <= 0) return reply(400, { error: 'Invalid payment data.' });
  const db = serverClient();
  const { data, error } = await db.rpc('apply_verified_billplz_payment', {
    p_bill_id: billId,
    p_paid: paid,
    p_amount_cents: cents,
    p_callback: Object.fromEntries(values.entries()),
  });
  if (error) return reply(500, { error: 'Could not apply payment callback.' });
  return reply(200, { received: true, result: data });
};
