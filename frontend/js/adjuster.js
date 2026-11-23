import { api, accounts, sha256Hex } from './api.js';
import { $, el, fillAccounts, formatBytes, formatDate, photoCard, toast } from './ui.js';

const PAGE_SIZE = 6;
const state = { claim: null, items: [], page: 0 };
const adjusterId = () => Number($('#account').value);

fillAccounts($('#account'), accounts.filter((a) => a.role === 'Adjuster'));

// RAI: retrieve all evidence for a claim
async function loadClaim(keepSelection) {
  const claimId = $('#claim').value.trim().toUpperCase();
  try {
    const { claim, items } = await api.list(claimId);
    Object.assign(state, { claim, items, page: keepSelection ? state.page : 0 });
    $('#claim-summary').textContent =
      `${claim.claimRef} · ${claim.policyholder} · ${claim.eventName} · policy ${claim.policyNumber} · ${claim.claimStatus} · ${items.length} photo(s)`;
    const areas = [...new Set(items.map((i) => i.metadata?.area).filter(Boolean))];
    $('#filter-area').replaceChildren(el('option', { value: '', textContent: 'All' }), ...areas.map((a) => el('option', { textContent: a })));
    render();
    if (!keepSelection) $('#detail').replaceChildren(el('p', { className: 'muted', textContent: 'Select a photo to see its details.' }));
  } catch (err) {
    Object.assign(state, { claim: null, items: [] });
    $('#claim-summary').textContent = '';
    render();
    toast(err.message, 'error');
  }
}

function filtered() {
  const area = $('#filter-area').value;
  const status = $('#filter-status').value;
  return state.items.filter((i) => (!area || i.metadata?.area === area) && (!status || i.status === status));
}

function render() {
  const items = filtered();
  const pages = Math.max(1, Math.ceil(items.length / PAGE_SIZE));
  state.page = Math.min(state.page, pages - 1);
  const slice = items.slice(state.page * PAGE_SIZE, (state.page + 1) * PAGE_SIZE);
  $('#grid').replaceChildren(...(slice.length ? slice.map((i) => photoCard(i, select)) : [el('p', { className: 'muted', textContent: 'No photos match.' })]));
  $('#page-label').textContent = `Page ${state.page + 1} of ${pages}`;
  $('#prev').disabled = state.page === 0;
  $('#next').disabled = state.page >= pages - 1;
}

// RIPS: retrieve one item with fresh read link, metadata and audit trail
async function select(item, card) {
  document.querySelectorAll('.photo.selected').forEach((c) => c.classList.remove('selected'));
  card?.classList.add('selected');
  try {
    showDetail(await api.get(item.evidenceId));
  } catch (err) {
    toast(err.message, 'error');
  }
}

function fact(label, value) {
  return [el('dt', { textContent: label }), el('dd', { textContent: value ?? '–' })];
}

function showDetail(item) {
  const meta = item.metadata ?? {};
  const exif = meta.exif ?? {};
  const gps = exif.gps ? `${exif.gps.lat}, ${exif.gps.lon}` : null;
  const voided = item.status === 'Voided';

  const caption = el('textarea', { id: 'edit-caption', rows: 3, maxLength: 500, value: item.caption ?? '', disabled: voided });
  const tags = el('input', { id: 'edit-tags', value: (meta.damageTags ?? []).join(', '), disabled: voided });
  const verifyResult = el('span', { className: 'muted' });

  const translated = meta.captionLang && meta.captionLang !== 'en' && meta.captionEn
    ? el('p', { className: 'translation' }, el('strong', { textContent: `Translated from ${meta.captionLang.toUpperCase()}: ` }), meta.captionEn)
    : null;

  const save = el('button', { type: 'button', className: 'primary', textContent: 'Save changes', disabled: voided });
  const voidBtn = el('button', { type: 'button', className: 'danger', textContent: 'Void item', disabled: voided });
  const verify = el('button', { type: 'button', textContent: 'Verify integrity' });

  // UIPS: update caption and tags (the photo itself never changes)
  save.addEventListener('click', async () => {
    save.disabled = true;
    try {
      const damageTags = tags.value.split(',').map((t) => t.trim().toLowerCase()).filter(Boolean);
      await api.update(item.evidenceId, { userId: adjusterId(), caption: caption.value.trim(), damageTags });
      toast('Changes saved');
      await loadClaim(true);
      showDetail(await api.get(item.evidenceId));
    } catch (err) {
      toast(err.message, 'error');
      save.disabled = false;
    }
  });

  // DIPS: void (soft delete). The original is kept for the retention period.
  voidBtn.addEventListener('click', async () => {
    const reason = prompt('Reason for voiding this photo (kept in the audit log):');
    if (!reason) return;
    try {
      await api.void(item.evidenceId, adjusterId(), reason);
      toast('Photo voided');
      await loadClaim(true);
      showDetail(await api.get(item.evidenceId));
    } catch (err) {
      toast(err.message, 'error');
    }
  });

  // Downloads the original through its SAS link and compares the hash stored at upload
  verify.addEventListener('click', async () => {
    verifyResult.textContent = 'Checking…';
    try {
      const res = await fetch(item.readUrl);
      if (!res.ok) throw new Error(`download failed (${res.status})`);
      const ok = (await sha256Hex(await res.arrayBuffer())) === item.sha256;
      verifyResult.textContent = ok ? '✓ Matches the hash recorded at upload' : '✗ Does not match the recorded hash';
      verifyResult.className = ok ? 'ok' : 'error';
    } catch (err) {
      verifyResult.textContent = `Could not verify: ${err.message}`;
      verifyResult.className = 'error';
    }
  });

  $('#detail').replaceChildren(
    el('img', { src: item.readUrl, alt: item.caption || item.fileName, className: 'preview' }),
    el('dl', { className: 'facts' },
      ...fact('Status', item.status),
      ...fact('Captured', exif.capturedUtc ? formatDate(exif.capturedUtc) : null),
      ...fact('GPS', gps),
      ...fact('Device', exif.device),
      ...fact('Uploaded', `${formatDate(item.uploadedUtc)} by ${item.uploadedByName}`),
      ...fact('File', `${item.fileName} · ${formatBytes(item.sizeBytes)}`),
      ...fact('SHA-256', item.sha256)
    ),
    el('div', { className: 'verify' }, verify, verifyResult),
    el('label', {}, 'Caption (editable)', caption),
    translated,
    el('label', {}, 'Damage tags (comma separated)', tags),
    el('div', { className: 'actions' }, save, voidBtn),
    el('details', {},
      el('summary', { textContent: `Audit trail (${item.audit.length})` }),
      el('ol', { className: 'audit' }, ...item.audit.map((a) =>
        el('li', { textContent: `${formatDate(a.atUtc)} · ${a.action} by ${a.byUser}${a.detail ? ` · ${a.detail}` : ''}` })))
    )
  );
}

$('#search').addEventListener('submit', (e) => {
  e.preventDefault();
  if (!$('#claim').checkValidity()) return toast('Claim reference looks like CS-12345', 'error');
  loadClaim();
});
$('#filter-area').addEventListener('change', () => { state.page = 0; render(); });
$('#filter-status').addEventListener('change', () => { state.page = 0; render(); });
$('#prev').addEventListener('click', () => { state.page--; render(); });
$('#next').addEventListener('click', () => { state.page++; render(); });

loadClaim();
