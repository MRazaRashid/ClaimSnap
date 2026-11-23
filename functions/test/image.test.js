const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { inspectImage, MAX_BYTES } = require('../src/image');

const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00]);
const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00]);

test('accepts a JPEG and returns its SHA-256', async () => {
  const { status, body } = await inspectImage(jpeg);
  assert.equal(status, 200);
  assert.equal(body.contentType, 'image/jpeg');
  assert.equal(body.sizeBytes, jpeg.length);
  assert.equal(body.sha256, crypto.createHash('sha256').update(jpeg).digest('hex'));
});

test('detects PNG from its signature', async () => {
  const { status, body } = await inspectImage(png);
  assert.equal(status, 200);
  assert.equal(body.contentType, 'image/png');
});

test('returns empty EXIF fields when the photo has none', async () => {
  const { body } = await inspectImage(jpeg);
  assert.deepEqual(body.exif, { capturedUtc: null, gps: null, device: null });
});

test('rejects other file types with 415', async () => {
  const gif = Buffer.from('GIF89a', 'ascii');
  assert.equal((await inspectImage(gif)).status, 415);
});

test('rejects files over 10 MB with 413', async () => {
  const big = Buffer.alloc(MAX_BYTES + 1);
  jpeg.copy(big);
  assert.equal((await inspectImage(big)).status, 413);
});

test('rejects an empty file with 400', async () => {
  assert.equal((await inspectImage(Buffer.alloc(0))).status, 400);
});
