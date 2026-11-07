// ya-search.js — поиск по Яндекс Архиву из браузера, где ВЫ вошли в Яндекс ID.
//
// С осени 2026 года Яндекс Архив без входа не отдаёт ни поиск, ни каталог (307 → /archive),
// поэтому perl- и powershell-скрипты набора к нему больше не подходят. Здесь тот же разбор
// (<script id="__NEXT_DATA__">), но запросы идут от имени вашей сессии, из страницы сайта.
// Пароли и куки скрипт не читает и никуда не отправляет.
//
// Как пользоваться:
//   1. Откройте https://yandex.ru/archive и войдите в Яндекс ID сами.
//   2. Откройте консоль (Cmd+Option+J в Chrome), вставьте весь этот файл, нажмите Enter.
//   3. Вызывайте:
//        await yaProbe(['йога', 'іога', 'иога'], { from: 1860, to: 1918 })
//        await yaSearch('в Бронницком уезде', { p: 1 })
//        await yaPageText('<nodeId>', 4, /Быков/)
//   Паузы между запросами 2,5 с. Не гоняйте большие серии: условия сервиса запрещают
//   массовое копирование.
//
// Если Claude работает через Claude in Chrome, он выполняет тот же код во вкладке с вашей
// сессией (результаты складывает в window.__x и читает порциями — вывод инструмента короткий).

async function yaNextData(url) {
  const r = await fetch(url, { credentials: 'include' });
  if (r.redirected && new URL(r.url).pathname.replace(/\/$/, '') === '/archive')
    throw new Error('перенаправило на /archive: вы не вошли в Яндекс ID или сессия кончилась');
  const html = await r.text();
  const m = html.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) throw new Error('нет __NEXT_DATA__ (проверка на робота или смена вёрстки?)');
  return JSON.parse(m[1]).props.pageProps;
}

async function yaSearch(q, o = {}) {
  let u = '/archive/search?text=' + encodeURIComponent(q);
  if (o.index) u += '&index=' + o.index;          // по умолчанию без индекса = весь корпус
  if (o.from) u += '&dateFrom=' + o.from;
  if (o.to) u += '&dateTo=' + o.to;
  if (o.fuzzy) u += '&fuzzy=1';
  u += '&p=' + (o.p || 1);
  const pp = await yaNextData(u);
  return {
    total: pp.totalDocs,
    pages: pp.totalPages,
    items: (pp.items || []).map(i => ({
      date: i.dateFrom, src: i.namepath, node: i.parentId, page: i.sheetPageNumber,
      url: 'https://yandex.ru/archive/catalog/' + i.parentId + '/' + i.sheetPageNumber,
      snippet: (i.snippet || '').replace(/\x07\[/g, '«').replace(/\x07\]/g, '»'),
    })),
  };
}

// Зонд по вариантам написания: сколько находок на каждый.
async function yaProbe(variants, o = {}) {
  const out = [];
  for (const v of variants) {
    try { out.push({ variant: v, total: (await yaSearch(v, o)).total }); }
    catch (e) { out.push({ variant: v, total: 'нет ответа: ' + e.message }); break; }
    await new Promise(r => setTimeout(r, 2500));
  }
  return out;
}

// Распознанный текст листа; match — регулярка для отбора блоков.
async function yaPageText(nodeId, page, match) {
  const pp = await yaNextData('/archive/catalog/' + nodeId + '/' + page);
  let blocks = (pp.currentNode.textBlocks || []).map(b => (b.text || '').trim());
  if (match) blocks = blocks.filter(t => match.test(t));
  return { src: pp.currentNode.namepath, text: blocks.join('\n') };
}
