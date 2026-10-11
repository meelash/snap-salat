// Signs that an update deserves a second look. Nothing is rejected for
// these; the admin page highlights them.

import { zonedParts } from './sun.mjs';

/** Great-circle distance in metres. */
export function distanceMetres(lat1, lng1, lat2, lng2) {
  const rad = Math.PI / 180;
  const a = Math.sin(((lat2 - lat1) * rad) / 2) ** 2
    + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(((lng2 - lng1) * rad) / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(a));
}

const describeDistance = (m) => (m < 1000 ? `${Math.round(m / 10) * 10} m` : `${(m / 1000).toFixed(m < 10000 ? 1 : 0)} km`);

const to12h = (minutes) => {
  const h = Math.floor(minutes / 60) % 24, m = minutes % 60;
  return `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`;
};

/**
 * Review notes for a stored submission row:
 * [{level: 'flag' | 'note', text}]. Flags suggest the photo may not be
 * what it claims; notes are context.
 */
export function reviewNotes(sub, settings) {
  const notes = [];
  const masjidLat = parseFloat(settings.latitude), masjidLng = parseFloat(settings.longitude);
  const limit = parseInt(settings.flag_distance_m, 10) || 500;

  if (sub.photo_lat != null && sub.photo_lng != null) {
    if (Number.isFinite(masjidLat) && Number.isFinite(masjidLng)) {
      const d = distanceMetres(masjidLat, masjidLng, sub.photo_lat, sub.photo_lng);
      if (d > limit) notes.push({ level: 'flag', text: `Taken ${describeDistance(d)} from the masjid` });
      else notes.push({ level: 'ok', text: `Taken at the masjid (${describeDistance(d)} away)` });
    } else {
      notes.push({ level: 'note', text: 'Has a location; set the masjid’s location in Settings to check it' });
    }
  } else {
    notes.push({ level: 'note', text: 'No location in the photo' });
  }

  if (sub.display_clock && sub.captured_at_ms) {
    const p = zonedParts(sub.captured_at_ms, settings.timezone);
    const shot = p.hour * 60 + p.minute;
    const [h, m] = sub.display_clock.split(':').map(Number);
    let diff = Math.abs(h * 60 + m - shot) % 720;
    diff = Math.min(diff, 720 - diff); // the board's clock is 12-hour
    const limitMin = parseInt(settings.flag_clock_minutes, 10) || 15;
    if (diff > limitMin) {
      notes.push({ level: 'flag', text: `Board clock showed ${to12h(h * 60 + m)}, but the photo is from ${to12h(shot)}` });
    }
  }

  if (sub.captured_at_source === 'file') {
    notes.push({ level: 'flag', text: 'Photo time comes from the file date, not the camera' });
  }
  return notes;
}
