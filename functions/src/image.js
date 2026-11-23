const crypto = require('node:crypto');
const exifr = require('exifr');

const MAX_BYTES = 10 * 1024 * 1024;

// The file's first bytes decide its type, not the name or the header the client sent
const SIGNATURES = {
  'image/jpeg': [0xff, 0xd8, 0xff],
  'image/png': [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
};

function detectType(buffer) {
  return Object.keys(SIGNATURES).find((type) =>
    SIGNATURES[type].every((byte, i) => buffer[i] === byte)
  );
}

async function readExif(buffer) {
  try {
    const [tags, gps] = await Promise.all([
      exifr.parse(buffer, ['DateTimeOriginal', 'Make', 'Model']),
      exifr.gps(buffer),
    ]);
    const device = [tags?.Make, tags?.Model].filter(Boolean).join(' ');
    return {
      capturedUtc: tags?.DateTimeOriginal instanceof Date ? tags.DateTimeOriginal.toISOString() : null,
      gps: gps ? { lat: +gps.latitude.toFixed(5), lon: +gps.longitude.toFixed(5) } : null,
      device: device || null,
    };
  } catch {
    // Screenshots and edited photos often have no EXIF block at all
    return { capturedUtc: null, gps: null, device: null };
  }
}

async function inspectImage(buffer) {
  if (!buffer.length) return { status: 400, body: { error: 'The file is empty' } };
  if (buffer.length > MAX_BYTES) return { status: 413, body: { error: 'Photos must be 10 MB or smaller' } };

  const contentType = detectType(buffer);
  if (!contentType) return { status: 415, body: { error: 'Only JPEG and PNG photos are accepted' } };

  return {
    status: 200,
    body: {
      contentType,
      sizeBytes: buffer.length,
      sha256: crypto.createHash('sha256').update(buffer).digest('hex'),
      exif: await readExif(buffer),
    },
  };
}

module.exports = { inspectImage, MAX_BYTES };
