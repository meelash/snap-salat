// Sunset (and sunrise) for a date and place, accurate to about a minute.
// Standard solar-position formulas (as used by NOAA and the suncalc
// library): mean anomaly → equation of centre → ecliptic longitude →
// declination → hour angle at the apparent horizon (-0.833°, which allows
// for refraction and the sun's radius).

const rad = Math.PI / 180;
const J1970 = 2440588;
const J2000 = 2451545;
const dayMs = 86400000;

const toJulian = (ms) => ms / dayMs - 0.5 + J1970;
const fromJulian = (j) => (j + 0.5 - J1970) * dayMs;

/**
 * Sunrise and sunset as UTC milliseconds for the calendar day that
 * contains `utcNoonMs` at the given location. Returns nulls in polar
 * day/night.
 */
export function sunTimes(utcNoonMs, lat, lng) {
  const lw = -lng * rad;
  const phi = lat * rad;
  const d = toJulian(utcNoonMs) - J2000;
  const n = Math.round(d - 0.0009 - lw / (2 * Math.PI));
  const ds = 0.0009 + lw / (2 * Math.PI) + n;
  const M = rad * (357.5291 + 0.98560028 * ds);
  const C = rad * (1.9148 * Math.sin(M) + 0.02 * Math.sin(2 * M) + 0.0003 * Math.sin(3 * M));
  const L = M + C + rad * 102.9372 + Math.PI;
  const dec = Math.asin(Math.sin(L) * Math.sin(rad * 23.4397));
  const jNoon = J2000 + ds + 0.0053 * Math.sin(M) - 0.0069 * Math.sin(2 * L);
  const h0 = -0.833 * rad;
  const cosH = (Math.sin(h0) - Math.sin(phi) * Math.sin(dec)) / (Math.cos(phi) * Math.cos(dec));
  if (cosH < -1 || cosH > 1) return { sunrise: null, sunset: null };
  const w = Math.acos(cosH);
  const jSet = J2000 + 0.0009 + (w + lw) / (2 * Math.PI) + n + 0.0053 * Math.sin(M) - 0.0069 * Math.sin(2 * L);
  const jRise = jNoon - (jSet - jNoon);
  return { sunrise: fromJulian(jRise), sunset: fromJulian(jSet) };
}

/** Wall-clock parts of a UTC instant in an IANA time zone. */
export function zonedParts(ms, timeZone) {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(new Date(ms));
  const get = (t) => Number(parts.find((p) => p.type === t).value);
  return { year: get('year'), month: get('month'), day: get('day'), hour: get('hour'), minute: get('minute'), second: get('second') };
}

/** Today's date (YYYY-MM-DD) in a time zone. */
export function localDate(ms, timeZone) {
  const p = zonedParts(ms, timeZone);
  return `${p.year}-${String(p.month).padStart(2, '0')}-${String(p.day).padStart(2, '0')}`;
}

/**
 * Local sunset as minutes after midnight for `date` (YYYY-MM-DD) at a
 * place, in its time zone. Null if the sun doesn't set.
 */
export function sunsetMinutes(date, lat, lng, timeZone) {
  // Noon UTC shifted by longitude is safely inside the local day.
  const [y, m, d] = date.split('-').map(Number);
  const approxLocalNoon = Date.UTC(y, m - 1, d, 12) - (lng / 15) * 3600000;
  const { sunset } = sunTimes(approxLocalNoon, lat, lng);
  if (sunset == null) return null;
  const p = zonedParts(sunset, timeZone);
  return p.hour * 60 + p.minute + p.second / 60;
}
