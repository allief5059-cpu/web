export const MAX_RENTAL_HOURS = 168;

export function validateRentalRequestFields({ accountId, nickname, telegramUsername = '', durationHours }) {
  const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const cleanNickname = String(nickname || '').trim();
  const cleanTelegram = String(telegramUsername || '').trim();
  const hours = Number(durationHours);
  if (!uuidPattern.test(String(accountId || ''))) return 'Choose an available listing.';
  if (cleanNickname.length < 1 || cleanNickname.length > 100) return 'Enter a nickname (up to 100 characters).';
  if (cleanTelegram && (cleanTelegram.length > 64 || !/^@?[A-Za-z0-9_]{5,32}$/.test(cleanTelegram))) return 'Check the optional Telegram username.';
  if (!Number.isInteger(hours) || hours < 1 || hours > MAX_RENTAL_HOURS) return `Choose between 1 and ${MAX_RENTAL_HOURS} hours.`;
  return null;
}

export function rentalQuote(hourlyRate, durationHours) {
  const rate = Number(hourlyRate);
  const hours = Number(durationHours);
  if (!Number.isFinite(rate) || rate <= 0 || !Number.isInteger(hours) || hours < 1 || hours > MAX_RENTAL_HOURS) return null;
  return Math.round((rate * hours + Number.EPSILON) * 100) / 100;
}
