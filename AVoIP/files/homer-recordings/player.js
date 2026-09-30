const search = document.getElementById('search');
const results = document.getElementById('results');
const status = document.getElementById('status');
const player = document.getElementById('player');
let recordings = [];

function render() {
  const term = search.value.trim().toLowerCase();
  const matches = recordings.filter(item => `${item.name} ${item.mtime}`.toLowerCase().includes(term));
  results.replaceChildren();
  for (const item of matches.slice(0, 200)) {
    const row = document.createElement('li');
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = item.name;
    button.addEventListener('click', () => {
      player.src = `/recordings/files/${encodeURIComponent(item.name)}`;
      player.hidden = false;
      player.play().catch(() => {});
    });
    const time = document.createElement('small');
    time.textContent = item.mtime || '';
    row.append(button, time);
    results.append(row);
  }
  status.textContent = `${matches.length} recording${matches.length === 1 ? '' : 's'} found`;
}

search.addEventListener('input', render);
fetch('/recordings/files/', { credentials: 'same-origin', cache: 'no-store' })
  .then(response => {
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  })
  .then(items => {
    recordings = items
      .filter(item => item.type === 'file' && /^[0-9a-f-]{36}\.wav$/i.test(item.name))
      .sort((a, b) => Date.parse(b.mtime) - Date.parse(a.mtime));
    render();
  })
  .catch(() => { status.textContent = 'Could not load recordings. Refresh after signing in to Homer.'; });
