import { getJson } from './base.js';

(() => {
  const userEl = document.getElementById('loginUser');
  const passEl = document.getElementById('loginPass');
  const btnEl = document.getElementById('loginBtn');
  const statusEl = document.getElementById('loginStatus');

  async function doLogin() {
    const username = String(userEl.value || '').trim();
    const password = String(passEl.value || '');
    if (!username || !password) {
      statusEl.textContent = 'username and password are required';
      return;
    }
    statusEl.textContent = 'Logging in...';
    await getJson('/_fn/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password }),
    });
    window.location.href = '/console';
  }

  btnEl.addEventListener('click', () => {
    doLogin().catch((err) => {
      statusEl.textContent = String(err && err.message ? err.message : err);
    });
  });

  passEl.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') btnEl.click();
  });
})();

