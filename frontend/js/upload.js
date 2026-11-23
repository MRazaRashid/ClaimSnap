import { api, accounts, withRetry, fileToBase64, MAX_BYTES, ACCEPTED_TYPES } from './api.js';
import { $, el, fillAccounts, formatBytes, photoCard, toast } from './ui.js';

const form = $('#upload-form');
fillAccounts($('#account'), accounts.filter((a) => a.role === 'Policyholder'));

$('#files').addEventListener('change', (e) => {
  const n = e.target.files.length;
  $('#drop-text').textContent = n ? `${n} photo${n > 1 ? 's' : ''} selected` : 'Tap to take or choose photos';
});

function checkFile(file) {
  if (!ACCEPTED_TYPES.includes(file.type)) return 'Only JPEG and PNG photos are accepted';
  if (file.size > MAX_BYTES) return 'Photo is larger than 10 MB';
  return null;
}

async function uploadOne(file, claimId, fields, line) {
  const problem = checkFile(file);
  if (problem) throw new Error(problem);

  // The id is created here so a retry after a dropped connection can't store the photo twice
  const evidence = { evidenceId: crypto.randomUUID(), fileName: file.name, data: await fileToBase64(file), ...fields };
  try {
    await withRetry(() => api.upload(claimId, evidence));
  } catch (err) {
    if (err.status !== 409) throw err; // 409 = an earlier attempt already got through
  }
  line.textContent = `${file.name} · ${formatBytes(file.size)} · uploaded`;
}

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const files = [...$('#files').files];
  const claimId = $('#claim').value.trim().toUpperCase();
  if (!$('#claim').checkValidity()) return toast('Claim reference looks like CS-12345', 'error');
  if (!files.length) return toast('Choose at least one photo', 'error');

  const area = $('#area').value;
  const fields = { userId: Number($('#account').value), caption: $('#caption').value.trim(), area, damageTags: [area.toLowerCase()] };
  const queue = $('#queue');
  queue.replaceChildren();
  $('#submit').disabled = true;

  let done = 0;
  for (const file of files) {
    $('#progress').textContent = `Uploading ${done + 1} of ${files.length}…`;
    const line = queue.appendChild(el('li', { textContent: `${file.name} · uploading…` }));
    try {
      await uploadOne(file, claimId, fields, line);
      line.className = 'ok';
      done++;
    } catch (err) {
      line.className = 'error';
      line.textContent = `${file.name} · ${err.message}`;
    }
  }

  $('#progress').textContent = `${done} of ${files.length} uploaded`;
  $('#submit').disabled = false;
  if (done) {
    toast(`${done} photo${done > 1 ? 's' : ''} added to ${claimId}`);
    form.reset();
    $('#claim').value = claimId;
    $('#drop-text').textContent = 'Tap to take or choose photos';
  }
  loadGallery(claimId);
});

async function loadGallery(claimId = $('#claim').value.trim().toUpperCase()) {
  const gallery = $('#gallery');
  try {
    const { items } = await api.list(claimId);
    const active = items.filter((i) => i.status === 'Active');
    gallery.replaceChildren(...(active.length ? active.map((i) => photoCard(i)) : [el('p', { className: 'muted', textContent: 'No photos yet.' })]));
  } catch (err) {
    gallery.replaceChildren(el('p', { className: 'muted', textContent: err.message }));
  }
}

$('#claim').addEventListener('change', () => loadGallery());
loadGallery();
