import { endpoints } from './config.js';

export const MAX_BYTES = 10 * 1024 * 1024;
export const ACCEPTED_TYPES = ['image/jpeg', 'image/png'];

// Seeded in 01-schema.sql. Sign-in is simulated; the stored procedures enforce who may do what.
export const accounts = [
  { id: 1, name: 'Aoife Byrne', role: 'Policyholder' },
  { id: 2, name: 'Daniel Okafor', role: 'Policyholder' },
  { id: 3, name: 'Sarah Whitmore', role: 'Adjuster' },
];

export class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// Logic App callback URLs contain the path template, e.g. .../claims/{claimId}/evidence?sig=...

function endpoint(name, params = {}) {
  const baseUrl = endpoints[name];

  // Do not call the website itself when an API endpoint is disabled.
  if (typeof baseUrl !== 'string' || !baseUrl.trim()) {
    throw new ApiError(
      503,
      'Demo mode — evidence API is currently unavailable.'
    );
  }

  return Object.entries(params).reduce(
    (url, [key, value]) =>
      url.replace(
        new RegExp(`\\{${key}\\}|%7B${key}%7D`, 'i'),
        encodeURIComponent(value)
      ),
    baseUrl
  );
}


async function request(url, { method = 'GET', body } = {}) {
  let res;
  try {
    res = await fetch(url, {
      method,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new ApiError(0, 'Network error. Check your connection and try again.');
  }
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) throw new ApiError(res.status, data?.error ?? data?.message ?? `Request failed (${res.status})`);
  return data;
}

// Retries network drops, throttling and server errors with backoff (1s, 2s, 4s)
export async function withRetry(task, attempts = 4) {
  for (let i = 1; ; i++) {
    try {
      return await task();
    } catch (err) {
      const transient = err.status === 0 || err.status === 429 || err.status >= 500;
      if (!transient || i === attempts) throw err;
      await new Promise((r) => setTimeout(r, 1000 * 2 ** (i - 1)));
    }
  }
}

export const api = {
  upload: (claimId, evidence) => request(endpoint('iups', { claimId }), { method: 'POST', body: evidence }),
  list: (claimId) => request(endpoint('rai', { claimId })),
  get: (evidenceId) => request(endpoint('rips', { evidenceId })),
  update: (evidenceId, changes) => request(endpoint('uips', { evidenceId }), { method: 'PUT', body: changes }),
  void: (evidenceId, userId, reason) => {
    const url = new URL(endpoint('dips', { evidenceId }));
    url.searchParams.set('userId', userId);
    url.searchParams.set('reason', reason);
    return request(url, { method: 'DELETE' });
  },
};

export function fileToBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result.split(',')[1]);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

export async function sha256Hex(buffer) {
  const digest = await crypto.subtle.digest('SHA-256', buffer);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
