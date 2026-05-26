/* Helix Mobile Redesign — interactivity layer
   Pure-vanilla, no build step. Open index.html in any modern browser. */

(() => {
  const $  = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  /* ─── Mock data ─── */
  const orders = [
    { id: 'ORD-1042', customer: 'Sarah Mendel',  items: 3, total: 128.00, status: 'pending',    when: '9:14 AM',  initials: 'SM', grad: 'grad-1' },
    { id: 'ORD-1041', customer: 'James Tanaka',  items: 1, total:  42.00, status: 'processing', when: '9:02 AM',  initials: 'JT', grad: 'grad-2' },
    { id: 'ORD-1040', customer: 'Priya Raman',   items: 5, total: 214.50, status: 'completed',  when: '8:48 AM',  initials: 'PR', grad: 'grad-3' },
    { id: 'ORD-1039', customer: 'Omar Khalid',   items: 2, total:  68.00, status: 'completed',  when: 'Yesterday', initials: 'OK', grad: 'grad-4' },
    { id: 'ORD-1038', customer: 'Lucia Rosso',   items: 4, total: 152.00, status: 'cancelled',  when: 'Yesterday', initials: 'LR', grad: 'grad-2' },
    { id: 'ORD-1037', customer: 'Wei Chen',      items: 1, total:  18.00, status: 'completed',  when: 'Yesterday', initials: 'WC', grad: 'grad-1' },
  ];

  const inventory = [
    { id: 'p-001', emoji: '☕', name: 'Espresso beans 1kg',   sku: 'BEAN-ESP-1KG', stock:  8, max: 30, price: 24.00, status: 'low',       grad: 'grad-3' },
    { id: 'p-002', emoji: '🥛', name: 'Whole milk 2L',         sku: 'MLK-WHL-2L',   stock: 24, max: 40, price:  4.20, status: 'completed', grad: 'grad-4' },
    { id: 'p-003', emoji: '🥐', name: 'Almond croissant',      sku: 'PAS-ALM-CR',   stock: 14, max: 30, price:  4.50, status: 'completed', grad: 'grad-2' },
    { id: 'p-004', emoji: '🍪', name: 'Choc-chip cookie',      sku: 'PAS-COO-CC',   stock:  3, max: 24, price:  3.20, status: 'low',       grad: 'grad-3' },
    { id: 'p-005', emoji: '🧊', name: 'Cold-brew concentrate', sku: 'BEV-CB-1L',    stock: 11, max: 20, price: 14.00, status: 'completed', grad: 'grad-1' },
    { id: 'p-006', emoji: '🧉', name: 'Matcha powder 100g',    sku: 'MAT-100',      stock:  6, max: 18, price: 18.50, status: 'low',       grad: 'grad-2' },
  ];

  const staff = [
    { id: 's-001', name: 'Jamie Park',   role: 'Manager', dept: 'Operations', initials: 'JP', status: 'completed', grad: 'grad-1', shift: 'On shift' },
    { id: 's-002', name: 'Mira Okafor',  role: 'Cashier', dept: 'Front',      initials: 'MO', status: 'completed', grad: 'grad-2', shift: 'On shift' },
    { id: 's-003', name: 'Diego Alvarez',role: 'Barista', dept: 'Bar',        initials: 'DA', status: 'pending',   grad: 'grad-3', shift: 'Off' },
    { id: 's-004', name: 'Kenji Sato',   role: 'Baker',   dept: 'Kitchen',    initials: 'KS', status: 'completed', grad: 'grad-4', shift: 'On shift' },
    { id: 's-005', name: 'Aaliyah Ross', role: 'Cashier', dept: 'Front',      initials: 'AR', status: 'cancelled', grad: 'grad-2', shift: 'Inactive' },
  ];

  /* ─── Renderers ─── */
  const fmtMoney = n => '$' + n.toFixed(2);

  function renderOrders() {
    const list = $('#ordersList');
    if (!list) return;
    list.innerHTML = orders.map(o => `
      <li class="list-item" data-order="${o.id}">
        <span class="avatar ${o.grad}">${o.initials}</span>
        <div class="li-body">
          <div class="li-title">${o.id} · ${o.customer}</div>
          <div class="li-sub muted">${o.items} items · ${o.when}</div>
        </div>
        <div style="text-align:right;display:flex;flex-direction:column;align-items:flex-end;gap:4px;">
          <span class="amt">${fmtMoney(o.total)}</span>
          <span class="status ${o.status}">${o.status}</span>
        </div>
      </li>
    `).join('');
    $$('[data-order]', list).forEach(el => {
      el.addEventListener('click', () => {
        const id = el.getAttribute('data-order');
        const t = $('#odTitle'); if (t) t.textContent = `Order #${id}`;
        openSheet('orderDetail');
      });
    });
  }

  function renderInventory() {
    const list = $('#inventoryList');
    if (!list) return;
    list.innerHTML = inventory.map(p => {
      const pct = Math.max(6, Math.round((p.stock / p.max) * 100));
      const lowCls = p.status === 'low' ? 'low' : '';
      return `
        <li class="list-item" data-product="${p.id}">
          <span class="avatar ${p.grad}">${p.emoji}</span>
          <div class="li-body">
            <div class="li-title">${p.name}</div>
            <div class="li-sub muted">${p.sku} · ${fmtMoney(p.price)}</div>
            <div class="li-meta">
              <span class="stockbar ${lowCls}"><i style="--p:${pct}%"></i></span>
              <span class="muted">${p.stock} / ${p.max}</span>
              ${p.status === 'low' ? '<span class="status low">Low</span>' : ''}
            </div>
          </div>
        </li>
      `;
    }).join('');
    $$('[data-product]', list).forEach(el => {
      el.addEventListener('click', () => openSheet('restock'));
    });
  }

  function renderStaff() {
    const list = $('#staffList');
    if (!list) return;
    list.innerHTML = staff.map(s => `
      <li class="list-item" data-staff="${s.id}">
        <span class="avatar ${s.grad}">${s.initials}</span>
        <div class="li-body">
          <div class="li-title">${s.name}</div>
          <div class="li-sub muted">${s.role} · ${s.dept}</div>
        </div>
        <span class="status ${s.status}">${s.shift}</span>
      </li>
    `).join('');
    $$('[data-staff]', list).forEach(el => {
      el.addEventListener('click', () => toast('Staff details coming soon'));
    });
  }

  /* ─── Routing between screens ─── */
  const SCREENS_WITH_TABS = new Set(['dashboard','orders','inventory','sales','staff','profile']);

  function go(screenId, opts = {}) {
    if (!screenId) return;
    const target = $(`.screen[data-screen="${screenId}"]`);
    if (!target) return;
    $$('.screen').forEach(s => s.classList.remove('is-active'));
    target.classList.add('is-active');

    // Tabbar visibility
    const tabbar = $('#tabbar');
    tabbar.style.display = SCREENS_WITH_TABS.has(screenId) ? 'flex' : 'none';
    $$('.tab', tabbar).forEach(t => {
      t.classList.toggle('is-active', t.dataset.go === screenId);
    });

    // Reset scroll for the screen
    const scroller = $('.scroll', target);
    if (scroller) scroller.scrollTop = 0;

    if (opts.fromJump) $('.jump').value = '';
  }

  /* ─── Bottom sheets ─── */
  let openSheets = [];
  function openSheet(name) {
    const sheet = $(`.sheet[data-sheet="${name}"]`);
    if (!sheet) return;
    if (openSheets.includes(sheet)) return; // idempotent — clicking inside an open sheet shouldn't re-trigger
    const scrim = $('#scrim');
    sheet.hidden = false;
    scrim.hidden = false;
    // Two RAFs so the browser commits the initial `transform: translateY(100%)` before we transition to 0.
    requestAnimationFrame(() => requestAnimationFrame(() => sheet.classList.add('is-open')));
    openSheets.push(sheet);
  }
  function closeAllSheets() {
    const scrim = $('#scrim');
    const closing = openSheets.slice();
    openSheets = [];
    closing.forEach(s => {
      s.classList.remove('is-open');
      setTimeout(() => { if (!s.classList.contains('is-open')) s.hidden = true; }, 380);
    });
    if (scrim) scrim.hidden = true;
  }

  // Resolve the nearest sheet *trigger* (a non-panel element carrying data-sheet).
  // Walking stops if we hit a `.sheet` panel — its data-sheet identifies the panel,
  // not a click target, so bubbling clicks inside an open sheet must not re-open it.
  function findSheetTrigger(start) {
    for (let el = start; el && el !== document; el = el.parentElement) {
      if (el.classList && el.classList.contains('sheet')) return null;
      if (el.dataset && el.dataset.sheet) return el;
    }
    return null;
  }

  /* ─── Toast ─── */
  let toastTimer;
  function toast(msg) {
    const t = $('#toast');
    if (!t) return;
    t.textContent = msg;
    t.hidden = false;
    requestAnimationFrame(() => t.classList.add('is-on'));
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      t.classList.remove('is-on');
      setTimeout(() => { t.hidden = true; }, 260);
    }, 1800);
  }

  /* ─── Wire global click handlers ─── */
  document.addEventListener('click', (e) => {
    const closeEl = e.target.closest('[data-close]');
    if (closeEl) { closeAllSheets(); return; }

    const toastEl = e.target.closest('[data-toast]');
    if (toastEl) {
      toast(toastEl.dataset.toast);
      if (toastEl.closest('.sheet')) closeAllSheets();
      return; // toast actions are terminal — don't fall through to sheet/go
    }

    const sheetTrigger = findSheetTrigger(e.target);
    if (sheetTrigger) {
      const wantSheet = sheetTrigger.dataset.sheet;
      // Switching sheets: close current first if different
      if (openSheets.length) {
        const cur = openSheets[openSheets.length - 1];
        if (cur.dataset.sheet !== wantSheet) closeAllSheets();
      }
      openSheet(wantSheet);
    }

    // Navigation triggers — also valid on the same element as a sheet trigger
    // (e.g. dashboard quick-action tiles that both navigate AND open a sheet).
    const goEl = e.target.closest('[data-go]');
    if (goEl) go(goEl.dataset.go);
  });

  // Scrim closes sheets
  $('#scrim').addEventListener('click', closeAllSheets);

  // Form submissions are demo-only
  $$('form[data-form]').forEach(f => {
    f.addEventListener('submit', (e) => {
      e.preventDefault();
      const which = f.dataset.form;
      switch (which) {
        case 'login':     toast('Signed in'); go('dashboard'); break;
        case 'signup':    toast('Account created'); go('workspace'); break;
        case 'forgot':    toast('Reset link sent'); go('login'); break;
        case 'workspace': toast('Workspace ready'); go('dashboard'); break;
      }
    });
  });

  // Selectable chips toggle
  document.addEventListener('click', (e) => {
    const c = e.target.closest('.chip.selectable');
    if (!c) return;
    // Single-select within a chip-row when chips are not multi
    const row = c.closest('.chip-row, .chip-scroller');
    if (row && !row.classList.contains('chip-row-multi')) {
      $$('.chip', row).forEach(x => x.classList.remove('on'));
    }
    c.classList.toggle('on');
  });

  // Segmented pills (Day/Week/Month/Year)
  $$('.seg-pill').forEach(g => {
    g.addEventListener('click', e => {
      const b = e.target.closest('button'); if (!b) return;
      $$('button', g).forEach(x => x.classList.remove('on'));
      b.classList.add('on');
    });
  });

  // Roles selection inside invite sheet
  $$('.role').forEach(r => {
    r.addEventListener('click', () => {
      const group = r.parentElement;
      $$('.role', group).forEach(x => x.classList.remove('on'));
      r.classList.add('on');
      const i = $('input', r); if (i) i.checked = true;
    });
  });

  // Reveal password toggle
  $$('.reveal').forEach(btn => {
    btn.addEventListener('click', () => {
      const input = btn.previousElementSibling;
      if (!input) return;
      input.type = input.type === 'password' ? 'text' : 'password';
    });
  });

  // Platform & theme controls
  $$('[data-platform]').forEach(b => {
    b.addEventListener('click', () => {
      $$('[data-platform]').forEach(x => x.classList.remove('is-on'));
      b.classList.add('is-on');
      document.body.classList.remove('platform-ios','platform-android');
      document.body.classList.add('platform-' + b.dataset.platform);
    });
  });
  $$('[data-theme]').forEach(b => {
    b.addEventListener('click', () => {
      $$('[data-theme]').forEach(x => x.classList.remove('is-on'));
      b.classList.add('is-on');
      document.body.classList.remove('theme-light','theme-dark');
      document.body.classList.add('theme-' + b.dataset.theme);
    });
  });

  // Jump-to dropdown
  $('.jump').addEventListener('change', (e) => {
    const id = e.target.value;
    if (!id) return;
    closeAllSheets();
    go(id, { fromJump: true });
  });

  // ESC closes sheets
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') closeAllSheets();
  });

  /* ─── Init ─── */
  renderOrders();
  renderInventory();
  renderStaff();
  // Tabbar hidden until we land on a tab screen
  $('#tabbar').style.display = 'none';
})();
