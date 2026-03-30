let globalData = {};

async function loadData() {
  const resp = await fetch('/pulls/pulls.json');
  const data = await resp.json();
  return data;
}

function groupByBanner(records) {
  const map = new Map();
  for (const r of records) {
    const id = r.bannerId || r.bannerName || 'unknown';
    if (!map.has(id)) {
      map.set(id, { id, name: r.bannerName || id, items: [] });
    }
    map.get(id).items.push(r);
  }
  // сортировка по времени последней крутки
  const list = Array.from(map.values());
  for (const g of list) {
    g.items.sort((a, b) => {
      const ta = a.time || '';
      const tb = b.time || '';
      return ta.localeCompare(tb);
    });
    const last = g.items[g.items.length - 1];
    g.lastTime = last && last.time ? last.time : '';
  }

  list.sort((a, b) => b.lastTime.localeCompare(a.lastTime));
  return list;
}

function renderBannerList(container, groups, onSelect, typeLabel) {
  container.innerHTML = '';
  for (const g of groups) {
    const btn = document.createElement('button');
    btn.className = 'banner-btn';
    btn.innerHTML = `
      <img src="banners/${g.id}.jpg"
           onerror="this.style.display='none'"
           class="banner-thumb">
      <span>${g.name}</span>
    `;
    btn.onclick = () => onSelect(g);
    container.appendChild(btn);
  }
}

function calcStats(items, isWeapon) {
  const PITY_LIMIT = isWeapon ? 80 : 80;
  const total = items.length;
  const count6 = items.filter(i => i.rarity === 6).length;
  const count5 = items.filter(i => i.rarity === 5).length;
  const count4 = items.filter(i => i.rarity === 4).length;

  const EXCLUDE_BANNERS = ['Basic Headhunting', 'New Horizons'];

  const STANDARD_CHARS = [
    'Ardelia',
    'Last Rite',
    'Ember',
    'Lifeng',
    'Pogranichnik',
    // добавлять сюда новых стандартных героев
  ];

  // считаем pity между каждым 6★
  let pityHistory = [];
  let currentPity = 0;

  const limitedItems = isWeapon ? [] : items.filter(i =>
    !EXCLUDE_BANNERS.includes(i.bannerName)
  );

  const wins6 = limitedItems.filter(i =>
    i.rarity === 6 &&
    i.pity !== '-' &&
    !STANDARD_CHARS.includes(i.name)
  ).length;

  const losses6 = limitedItems.filter(i =>
    i.rarity === 6 &&
    i.pity !== '-' &&
    STANDARD_CHARS.includes(i.name)
  ).length;

  const winRate = (wins6 + losses6) > 0
    ? Math.round(wins6 / (wins6 + losses6) * 100)
    : 0;


  if (isWeapon) {
    // Старый подсчёт — счётчик
    let counter = 0;
    for (const item of items) {
      counter++;
      if (item.rarity >= 6) {
        pityHistory.push(counter);
        counter = 0;
      }
    }
    currentPity = counter;
  } else {
    // Новый подсчёт — берём из JSON, пропускаем free
    for (const item of items) {
      if (item.rarity === 6 && item.pity !== '-' && item.pity !== '') {
        pityHistory.push(Number(item.pity));
      }
    }
    const lastPaidItem = [...items].reverse().find(i => i.pity !== '-' && i.pity !== '' && i.pity != null);
    currentPity = !lastPaidItem ? 0
      : lastPaidItem.rarity === 6 ? 0
        : Number(lastPaidItem.pity);
  }
  const avgPity = pityHistory.length
    ? Math.round(pityHistory.reduce((a, b) => a + b, 0) / pityHistory.length) : 0;
  const minPity = pityHistory.length ? Math.min(...pityHistory) : 0;
  const maxPity = pityHistory.length ? Math.max(...pityHistory) : 0;
  const rate6 = total ? (count6 / total * 100).toFixed(1) : '0.0';

  return { total, count6, count5, count4, rate6, currentPity, avgPity, minPity, maxPity, PITY_LIMIT, wins6, losses6, winRate };
}

function calcOverall(allData) {
  const result = {};
  const EXCLUDE_BANNERS = ['Basic Headhunting', 'New Horizons'];
  for (const [type, groups] of Object.entries(allData)) {
    const allItems = groups.flatMap(g => g.items);
    const s = calcStats(allItems, type === 'weapon');

    // pity на каждый 6★ по всем баннерам
    const sixStars = allItems
      .filter(i => i.rarity === 6)
      .map(i => ({ name: i.name || i.charName || i.weaponName, pity: 0 }));

    // считаем pity истории по всем баннерам вместе
    const pityHistory = [];
    if (type === 'weapon') {
      // Старый подсчёт для оружия
      for (const g of groups) {
        let counter = 0;
        for (const item of g.items) {
          counter++;
          if (item.rarity >= 6) {
            pityHistory.push({ name: item.name || item.weaponName, pity: counter });
            counter = 0;
          }
        }
      }
    } else {
      // Новый подсчёт для персонажей — из JSON
      for (const g of groups) {
        if (EXCLUDE_BANNERS.includes(g.name)) continue;
        for (const item of g.items) {
          if (item.rarity === 6 && item.pity !== '-' && item.pity !== '') {
            pityHistory.push({ name: item.name || item.charName, pity: Number(item.pity) });
          }
        }
      }
    }

    result[type] = { ...s, pityHistory };
  }
  return result;
}

function renderOverall(allData) {
  const section = document.getElementById('overall-section');
  const stats = calcOverall(allData);
  let html = '';
  const labels = { character: 'Персонажи👤', weapon: 'Оружие⚔️' };

  for (const [type, s] of Object.entries(stats)) {
    const sorted = [...s.pityHistory].sort((a, b) => a.pity - b.pity);
    const luckiest = sorted.slice(0, 3);
    const unluckiest = sorted.slice(-3).reverse();

    html += `<div class="overall-block">
            <h3>${labels[type] || type}</h3>
            <div class="stats-bar" style="margin-bottom:12px">
                <div class="stat-item"><span class="stat-label"> Всего</span><span class="stat-value">${s.total}</span></div>
                <div class="stat-divider"></div>
                <div class="stat-item"><span class="stat-label">6★</span><span class="stat-value gold">${s.count6} (${s.rate6}%)</span></div>
                <div class="stat-item"><span class="stat-label">5★</span><span class="stat-value purple">${s.count5}</span></div>
                <div class="stat-item"><span class="stat-label">4★</span><span class="stat-value">${s.count4}</span></div>
                <div class="stat-divider"></div>
                <div class="stat-item"><span class="stat-label"> 6★</span><span class="stat-value">${s.avgPity}</span></div>
                <div class="stat-item"><span class="stat-label">Лучший pity</span><span class="stat-value green">${s.minPity}</span></div>
                <div class="stat-item"><span class="stat-label">Худший pity</span><span class="stat-value red">${s.maxPity}</span></div>
                ${type === 'character' ? `
                <div class="stat-divider"></div>
                <div class="stat-item">
                <span class="stat-label">50/50</span>
                <span class="stat-value ${s.winRate >= 50 ? 'green' : 'red'}">${s.wins6}W / ${s.losses6}L (${s.winRate}%)</span>
                </div>` : ''}
              </div>

            <div class="overall-charts">
              ${type !== 'weapon' ? `
              <div class="chart-wrap">
              <div class="chart-title">Пити на каждую 6★</div>
              <canvas id="chart-pity-${type}" height="160"></canvas>
            </div>` : ''}
                <div class="chart-wrap">
                    <div class="chart-title">Распределение редкостей по баннерам</div>
                    <canvas id="chart-bar-${type}" height="160"></canvas>
                </div>
            </div>

            <div class="luck-tables">
                <div>
                    <div class="luck-title green">🍀 Самые удачные 6★</div>
                    ${luckiest.map(x => `<div class="luck-row"><span class="rar-6">${x.name}</span><span class="luck-pity green">${x.pity} кр.</span></div>`).join('')}
                </div>
                <div>
                    <div class="luck-title red">💀 Самые долгие 6★</div>
                    ${unluckiest.map(x => `<div class="luck-row"><span class="rar-6">${x.name}</span><span class="luck-pity red">${x.pity} кр.</span></div>`).join('')}
                </div>
            </div>
        </div>`;
  }

  section.innerHTML = html;

  for (const [type, s] of Object.entries(stats)) {
    const isDark = document.documentElement.getAttribute('data-theme') !== 'light';
    const gridColor = 'rgba(255,255,255,0.06)';
    const tickColor = '#888';

    // --- График пити ---
    const ctx1 = document.getElementById(`chart-pity-${type}`)?.getContext('2d');
    if (ctx1 && s.pityHistory.length > 0) {
      const reversedHistory = [...s.pityHistory].reverse();
      new Chart(ctx1, {
        type: 'line',
        data: {
          labels: reversedHistory.map((_, i) => i + 1),
          datasets: [
            {
              data: reversedHistory.map(x => x.pity),
              label: 'Пити',
              borderColor: '#f5c842',
              backgroundColor: 'rgba(245,200,66,0.08)',
              pointBackgroundColor: reversedHistory.map(x =>
                x.pity >= 70 ? '#ff4444' : x.pity <= 20 ? '#44dd88' : '#f5c842'
              ),
              pointRadius: 5,
              tension: 0.3,
              fill: true,
            },
            {
              label: 'Среднее',
              data: s.pityHistory.map(() => s.avgPity),
              borderColor: 'rgba(255,80,80,0.5)',
              borderDash: [5, 5],
              pointRadius: 0,
              borderWidth: 1.5,
            }
          ]
        },
        options: {
          responsive: true,
          plugins: {
            legend: { display: false },
            tooltip: {
              callbacks: {
                title: items => reversedHistory[items[0].dataIndex]?.name || '',
                label: item => `Пити: ${item.raw}`
              }
            }
          },
          scales: {
            x: { ticks: { color: tickColor }, grid: { color: gridColor } },
            y: { ticks: { color: tickColor }, grid: { color: gridColor }, suggestedMin: 0, suggestedMax: type === 'weapon' ? 80 : 120 }
          }
        }
      });
    }

    // --- Столбчатый график по баннерам ---
    const EXCLUDE_BANNERS = ['Basic Headhunting', 'New Horizons'];
    const groups = allData[type].filter(g => !EXCLUDE_BANNERS.includes(g.name));
    const ctx2 = document.getElementById(`chart-bar-${type}`)?.getContext('2d');
    if (ctx2) {
      new Chart(ctx2, {
        type: 'bar',
        data: {
          labels: groups.map(g => g.name),
          datasets: [
            { label: '6★', data: groups.map(g => g.items.filter(i => i.rarity === 6).length), backgroundColor: '#f5c842' },
            { label: '5★', data: groups.map(g => g.items.filter(i => i.rarity === 5).length), backgroundColor: '#a855f7' },
            { label: '4★', data: groups.map(g => g.items.filter(i => i.rarity === 4).length), backgroundColor: '#3b82f6' },
          ]
        },
        options: {
          responsive: true,
          indexAxis: 'y',
          plugins: { legend: { labels: { color: tickColor, boxWidth: 12 } } },
          scales: {
            x: { stacked: true, ticks: { color: tickColor }, grid: { color: gridColor } },
            y: { stacked: true, ticks: { color: tickColor }, grid: { display: false } }
          }
        }
      });
    }
  }
}


function showOverall() {
  document.getElementById('overall-section').style.display = 'block';
  document.getElementById('table-wrap').style.display = 'none';
  document.getElementById('pulls-table').style.display = 'none';
  document.getElementById('stats-bar').style.display = 'none';
  document.getElementById('summary').style.display = 'none';
  document.getElementById('banner-header').style.display = 'none';
  renderOverall(globalData);
}

function showTable() {
  document.getElementById('overall-section').style.display = 'none';
  document.getElementById('table-wrap').style.display = '';
  document.getElementById('pulls-table').style.display = '';
  document.getElementById('stats-bar').style.display = '';
  document.getElementById('summary').style.display = '';
}

function renderTable(group, type) {
  showTable();
  const hero = document.getElementById('banner-hero');
  const header = document.getElementById('banner-header');
  const imgPath = `banners/${group.id}.jpg`;
  hero.src = imgPath;
  hero.style.display = '';
  header.style.display = '';

  const tbody = document.querySelector('#pulls-table tbody');
  const summary = document.querySelector('#summary');

  if (!group) {
    tbody.innerHTML = '';
    summary.textContent = 'Select a banner on the left.';
    return;
  }

  const items = group.items.slice().sort((a, b) => {
    const ta = a.time || '';
    const tb = b.time || '';
    return ta.localeCompare(tb);
  });


  const isWeapon = group.items[0]?.type === 'weapon';
  const s = calcStats(items, isWeapon);

  // рендер stats-bar
  const statsBar = document.getElementById('stats-bar');
  const pityClass = s.currentPity >= s.PITY_LIMIT - 10 ? 'warn' : '';
  statsBar.innerHTML = `
  <div class="stat-item">
    <span class="stat-label">Всего</span>
    <span class="stat-value">${s.total}</span>
  </div>
  <div class="stat-divider"></div>
  <div class="stat-item">
    <span class="stat-label">6★</span>
    <span class="stat-value gold">${s.count6} (${s.rate6}%)</span>
  </div>
  <div class="stat-item">
    <span class="stat-label">5★</span>
    <span class="stat-value purple">${s.count5}</span>
  </div>
  <div class="stat-item">
    <span class="stat-label">4★</span>
    <span class="stat-value">${s.count4}</span>
  </div>
  <div class="stat-divider"></div>
  <div class="stat-item">
    <span class="stat-label">Текущий pity</span>
    <span class="stat-value ${pityClass}">${s.currentPity} / ${s.PITY_LIMIT}</span>
  </div>
  <div class="stat-item">
    <span class="stat-label">Среднее на 6★</span>
    <span class="stat-value">${s.avgPity || '—'}</span>
  </div>
  <div class="stat-item">
    <span class="stat-label">Лучший pity</span>
    <span class="stat-value green">${s.minPity || '—'}</span>
  </div>
  <div class="stat-item">
    <span class="stat-label">Худший pity</span>
    <span class="stat-value red">${s.maxPity || '—'}</span>
  </div>
`;

  // показываем/скрываем колонку Free
  const table = document.getElementById('pulls-table');
  if (group.items[0]?.type === 'weapon') {
    table.classList.add('hide-free');
  } else {
    table.classList.remove('hide-free');
  }

  // summary
  const total = items.length;
  const sixes = items.filter(i => i.rarity === 6).length;
  const fives = items.filter(i => i.rarity === 5).length;
  const last = items[items.length - 1];
  summary.textContent =
    `${group.name} (${type}) — pulls: ${total}, 6★: ${sixes}, 5★: ${fives}, last: ${last?.time || 'n/a'}`;

  // table
  tbody.innerHTML = '';
  for (const r of items) {
    const tr = document.createElement('tr');
    const rarClass = r.rarity === 6 ? 'rar-6' : (r.rarity === 5 ? 'rar-5' : '');
    tr.innerHTML = `
      <td>${r.time}</td>
      <td class="${rarClass}">${r.name}</td>
      <td>${r.rarity}</td>
      <td>${r.pity ?? ''}</td>
      <td>${r.type !== 'weapon' ? (r.isFree ? 'Yes' : '') : ''}</td>
      <td>${r.seqId}</td>
    `;
    tbody.appendChild(tr);
  }

}

(async () => {
  const data = await loadData();
  const rawChars = data.characters || [];
  const rawWeaps = data.weapons || [];

  // Нормализуем поля под единый формат
  const chars = rawChars.map(r => ({
    seqId: r.seqId ?? r.SeqID ?? '',
    time: r.time ?? r.Time ?? '',
    name: r.name ?? r.Name ?? '',
    rarity: Number(r.rarity ?? r.Rarity ?? 0),
    bannerId: r.bannerId ?? r.BannerId ?? r.bannerName ?? r.Banner ?? 'unknown',
    bannerName: r.bannerName ?? r.BannerName ?? r.Banner ?? 'unknown',
    isFree: r.isFree ?? (r.IsFree === 'True' || r.IsFree === true),
    pity: r.pity ?? r.Pity ?? '',
    type: 'character'
  }));

  const weaps = rawWeaps.map(r => ({
    seqId: r.seqId ?? r.SeqID ?? '',
    time: r.time ?? r.Time ?? '',
    name: r.name ?? r.Name ?? r.weaponName ?? '',
    rarity: Number(r.rarity ?? r.Rarity ?? 0),
    bannerId: r.bannerId ?? r.BannerId ?? r.bannerName ?? r.BannerName ?? 'unknown',
    bannerName: r.bannerName ?? r.BannerName ?? 'unknown',
    isFree: false,
    pity: r.pity ?? r.Pity ?? '',
    type: 'weapon'
  }));

  const charGroups = groupByBanner(chars);
  const weapGroups = groupByBanner(weaps);

  globalData = { character: charGroups, weapon: weapGroups };

  const charContainer = document.getElementById('char-banners');
  const weapContainer = document.getElementById('weapon-banners');

  let currentBtn = null;

  function selectGroup(g, type, btn) {
    if (currentBtn) currentBtn.classList.remove('active');
    currentBtn = btn;
    if (currentBtn) currentBtn.classList.add('active');
    renderTable(g, type);
  }

  renderBannerList(charContainer, charGroups, (g) => {
    selectGroup(g, 'character', event.currentTarget);
  });
  renderBannerList(weapContainer, weapGroups, (g) => {
    selectGroup(g, 'weapon', event.currentTarget);
  });

  // авто‑выбор первого баннера если есть
  if (charGroups[0]) {
    renderTable(charGroups[0], 'character');
    if (charContainer.firstChild) charContainer.firstChild.classList.add('active');
  } else if (weapGroups[0]) {
    renderTable(weapGroups[0], 'weapon');
    if (weapContainer.firstChild) weapContainer.firstChild.classList.add('active');
  }
})();
