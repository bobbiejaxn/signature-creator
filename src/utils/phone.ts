/**
 * DIN 5008 / E.164 phone number sanitization for German numbers.
 * Formats phone numbers consistently for display in email signatures
 * and generates tel: links for clickable phone numbers.
 */

/**
 * Format a phone number according to DIN 5008 / E.164.
 * - Strips all non-digit characters (except leading +)
 * - Converts 00xxx to +xxx international prefix
 * - Converts German local 0xxx to +49 xxx
 * - Formats display as: +49 221 12345678 (grouped: country code, area code, subscriber)
 * - Returns original input if it can't be normalized
 */
export function sanitizePhoneE164(raw: string): string {
  if (!raw.trim()) return raw;

  // Strip everything except digits and leading +
  let digits = raw.replace(/[^\d+]/g, '');

  // Handle 00 international prefix → +
  if (digits.startsWith('00')) {
    digits = '+' + digits.slice(2);
  }

  // Handle German local 0 prefix → +49
  if (digits.startsWith('0') && !digits.startsWith('00')) {
    digits = '+49' + digits.slice(1);
  }

  // Validate: must start with + followed by 7-15 digits
  const match = digits.match(/^\+(\d{7,15})$/);
  if (!match) return raw; // Can't normalize — return original

  const numberPart = match[1];

  // Format for display
  // German numbers: +49 AREACODE SUBSCRIBER
  if (numberPart.startsWith('49')) {
    const national = numberPart.slice(2);
    // German area codes: 2-5 digits after 49
    // Mobile: 4 digits (170, 171, 172, etc.)
    // Landline: variable area codes
    const formatted = formatGermanNational(national);
    return `+49 ${formatted}`;
  }

  // International numbers: group in chunks of 3-4
  return `+${chunkDigits(numberPart)}`;
}

/**
 * Generate a tel: URI from a phone number (E.164 format, no spaces).
 */
export function phoneLinkE164(raw: string): string {
  if (!raw.trim()) return '';

  let digits = raw.replace(/[^\d+]/g, '');

  if (digits.startsWith('00')) {
    digits = '+' + digits.slice(2);
  }
  if (digits.startsWith('0') && !digits.startsWith('00') && !digits.startsWith('+')) {
    digits = '+49' + digits.slice(1);
  }

  // Remove any remaining non-digit characters except leading +
  digits = digits.replace(/(?!^\+)[^\d]/g, '');

  const match = digits.match(/^\+(\d{7,15})$/);
  if (!match) return `tel:${raw.replace(/[^\d+]/g, '')}`;

  return `tel:${digits}`;
}

/**
 * Check if a phone number differs from its sanitized form.
 * Returns the sanitized form if different, null if already clean.
 */
export function phoneFormatHint(raw: string): string | null {
  if (!raw.trim()) return null;
  const sanitized = sanitizePhoneE164(raw);
  if (sanitized === raw) return null;
  return sanitized;
}

function formatGermanNational(national: string): string {
  // Mobile prefixes (4 digits)
  const mobilePrefixes = ['170', '171', '172', '173', '174', '175', '160', '161', '162', '163', '176', '177', '178', '179', '150', '151', '152', '153', '155', '156', '157', '158', '159'];
  
  for (const prefix of mobilePrefixes) {
    if (national.startsWith(prefix)) {
      const rest = national.slice(prefix.length);
      return `${prefix} ${chunkDigits(rest)}`;
    }
  }

  // Common 3-digit area codes (major cities)
  const threeDigitAreas = ['30', '40', '69', '89', '221', '211', '711', '89'];
  for (const area of threeDigitAreas) {
    if (national.startsWith(area)) {
      const rest = national.slice(area.length);
      return `${area} ${chunkDigits(rest)}`;
    }
  }

  // 4-5 digit area codes
  // Try 4-digit then 5-digit area code
  if (national.length > 7) {
  // 4-5 digit area codes
    const area = national.slice(0, Math.min(national.length > 8 ? 5 : 4, national.length - 3));
    const rest = national.slice(area.length);
    return `${area} ${chunkDigits(rest)}`;
  }

  // Fallback: just chunk the whole number
  return chunkDigits(national);
}

function chunkDigits(digits: string): string {
  if (digits.length <= 4) return digits;
  // Group in chunks of 3-4 from the right
  const groups: string[] = [];
  let remaining = digits;
  while (remaining.length > 0) {
    if (remaining.length <= 3) {
      groups.unshift(remaining);
      break;
    }
    if (remaining.length === 5) {
      groups.unshift(remaining.slice(2));
      groups.unshift(remaining.slice(0, 2));
      break;
    }
    if (remaining.length === 6) {
      groups.unshift(remaining.slice(3));
      groups.unshift(remaining.slice(0, 3));
      break;
    }
    groups.unshift(remaining.slice(-3));
    remaining = remaining.slice(0, -3);
  }
  return groups.join(' ');
}