// The times the masjid actually publishes: what the board showed, with the
// admin's Maghrib policy applied for today's date.

import { sunsetMinutes, localDate } from './sun.mjs';

export const IQAMAH_KEYS = ['fajr', 'dhuhr', 'asr', 'maghrib', 'isha', 'jumuah'];
export const ADHAN_KEYS = ['fajr', 'sunrise', 'dhuhr', 'asr', 'maghrib', 'isha'];

const hhmm = (minutes) => {
  const m = Math.round(minutes) % 1440;
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
};

/** Maghrib for `date` under the admin's policy, or null if not computable. */
export function sunsetMaghrib(settings, date) {
  const lat = parseFloat(settings.latitude);
  const lng = parseFloat(settings.longitude);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  const sunset = sunsetMinutes(date, lat, lng, settings.timezone);
  if (sunset == null) return null;
  // Sunset minute rounds up: praying before the sun has fully set is the
  // mistake to avoid.
  let m = Math.ceil(sunset) + (parseInt(settings.maghrib_offset, 10) || 0);
  if (settings.maghrib_round === 'up5') m = Math.ceil(m / 5) * 5;
  return { time: hhmm(m), sunset: hhmm(Math.ceil(sunset)) };
}

/** Everything the public JSON, the widget and the API's GET return. */
export function publishedTimes(store, nowMs = Date.now()) {
  const settings = store.settings();
  const current = store.current();
  const date = localDate(nowMs, settings.timezone);
  const iqamah = { ...(current?.iqamah ?? {}) };
  let maghrib = { source: 'board' };
  if (settings.maghrib_mode === 'sunset') {
    const computed = sunsetMaghrib(settings, date);
    if (computed) {
      iqamah.maghrib = computed.time;
      maghrib = {
        source: 'sunset',
        sunset: computed.sunset,
        offset_minutes: parseInt(settings.maghrib_offset, 10) || 0,
      };
    }
  }
  return {
    masjid: { name: settings.masjid_name, timezone: settings.timezone },
    date,
    iqamah: Object.fromEntries(IQAMAH_KEYS.filter((k) => iqamah[k]).map((k) => [k, iqamah[k]])),
    adhan: current?.adhan ?? {},
    maghrib,
    captured_at: current?.captured_at ?? null,
    updated_at: current?.updated_at ?? null,
  };
}
