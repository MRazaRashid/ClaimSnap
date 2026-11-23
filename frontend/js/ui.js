// Small DOM helpers. Text is always set with textContent so captions can't inject HTML.
export const $ = (selector) => document.querySelector(selector);

export function el(tag, props = {}, ...children) {
  const node = Object.assign(document.createElement(tag), props);
  node.append(...children.filter((c) => c != null));
  return node;
}

export const formatBytes = (n) => (n >= 1048576 ? `${(n / 1048576).toFixed(1)} MB` : `${Math.ceil(n / 1024)} KB`);

export const formatDate = (iso) =>
  iso ? new Date(iso.endsWith('Z') ? iso : `${iso}Z`).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short' }) : '–';

export function fillAccounts(select, accounts) {
  select.replaceChildren(...accounts.map((a) => el('option', { value: a.id, textContent: `${a.name} (${a.role})` })));
}

let toastTimer;
export function toast(message, kind = 'ok') {
  const box = $('#toast');
  box.textContent = message;
  box.className = `toast show ${kind}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (box.className = 'toast'), 4000);
}

export function photoCard(item, onSelect) {
  const card = el(
    'button',
    { type: 'button', className: `photo ${item.status === 'Voided' ? 'voided' : ''}` },
    el('img', { src: item.readUrl, alt: item.caption || item.fileName, loading: 'lazy' }),
    el(
      'span',
      { className: 'photo-meta' },
      el('strong', { textContent: item.caption || item.fileName }),
      el('span', { className: `pill ${item.status.toLowerCase()}`, textContent: item.status })
    )
  );
  if (onSelect) card.addEventListener('click', () => onSelect(item, card));
  else card.disabled = true;
  return card;
}
