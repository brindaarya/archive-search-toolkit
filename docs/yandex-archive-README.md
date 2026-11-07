# Поиск по Яндекс Архиву без браузера

`yandex.ru/archive` рендерится на сервере (Next.js), поэтому результаты поиска и полный
распознанный текст страниц лежат прямо в HTML, в `<script id="__NEXT_DATA__">`.
Обычного `Invoke-WebRequest` достаточно: ни Playwright, ни авторизация, ни капча не нужны.

## Как пользоваться

```powershell
. .\ya-archive.ps1

# поиск по периодике за 1917-1935
Search-YaArchive -Text 'детская колония Быково' -DateFrom 1917 -DateTo 1935

# полный текст страницы газеты (NodeId и Page берутся из результата поиска)
Get-YaPageText -NodeId '8cddf8a4-368f-4f52-aacb-45ea5f28e012' -Page 4 -Match 'Быков|колони'
```

**Индекс лучше не указывать** (пустой = весь корпус, включая сканы ЦГА Москвы); `mass_media` режет выдачу до узкой периодики (ошибка найдена 18.09.2026).

`-Index`: `mass_media` — газеты и журналы, `archive` — архивные дела (метрики, ЗАГС,
описи), `books` — справочники и книги.

Пакетный прогон списка запросов с отчётом — см. `search-bykovo.ps1` как образец.
Результаты складываются в `results\`.

## Параметры URL поиска

| Параметр | Значение |
|---|---|
| `text` | запрос |
| `index` | `mass_media` / `archive` / `books` (**не** `searchIn`, тот игнорируется) |
| `dateFrom`, `dateTo` | годы, четыре цифры (`from`/`to`/`yearFrom` не работают) |
| `fuzzy=1` | неточное совпадение |
| `p` | номер страницы выдачи |

Ссылка на конкретный документ: `https://yandex.ru/archive/catalog/{parentId}/{sheetPageNumber}`.

## Грабли

`.ps1` с кириллицей нужно сохранять **в UTF-8 с BOM** — Windows PowerShell 5.1 иначе
читает файл как ANSI и валится на разборе строк. Починка:

```powershell
$f = '.\script.ps1'
$t = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($f, $t, (New-Object System.Text.UTF8Encoding($true)))
```
