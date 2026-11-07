<#
.SYNOPSIS
    Поиск дел по метрическим книгам, ревизским сказкам и исповедным ведомостям
    в ЦГА Москвы (cgamos.ru). Без регистрации, сканы там открыты.

.DESCRIPTION
    Расширенный поиск архива — обычная GET-форма /book_search/, раздел задаётся
    числовым кодом в placeToSearch. Выдача постраничная по 10 записей,
    страницы адресуются как &page=page-2.

    Про заголовки дел важно знать вот что: одно дело метрической книги — это
    подшивка по всей губернии, и в заголовке перечислены десятки приходов
    подряд, с номерами. Поэтому поиск по «БЫКОВО» находит дело, но не говорит,
    на каких листах наш приход: надо смотреть номер позиции в заголовке
    и уже в просмотрщике листать до неё.

    Быково — Бронницкий уезд, приход церкви Рождества Христова.
    По самому «Быково» отзываются только метрики: ревизские сказки
    и исповедные ведомости озаглавлены по уезду, село в заголовок не попадает,
    их надо искать по «БРОННИЦК».

.PARAMETER Section
    метрики | ревизии | исповедные | обыски | личные | кладбища | иноверцы

.PARAMETER YearFrom / YearTo
    Отфильтровать по пересечению с диапазоном лет дела.

.EXAMPLE
    .\Search-Cgamos.ps1 -Term БЫКОВО -YearFrom 1900 -YearTo 1918

.EXAMPLE
    .\Search-Cgamos.ps1 -Term БРОННИЦК -Section исповедные -OutCsv испов.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Term,
    [ValidateSet('метрики', 'ревизии', 'исповедные', 'обыски', 'личные', 'кладбища', 'иноверцы')]
    [string]$Section = 'метрики',
    [int]$YearFrom = 0,
    [int]$YearTo = 0,
    [string]$OutCsv = '',
    [int]$MaxPages = 40,
    [int]$DelayMs = 600
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$UserAgent = 'Search-Cgamos.ps1/1.0 (personal archive research)'
$root = 'https://cgamos.ru'

$codes = @{
    'метрики'    = '73,60'
    'иноверцы'   = '67,68,69,70'
    'ревизии'    = '63'
    'исповедные' = '65'
    'обыски'     = '76'
    'личные'     = '77'
    'кладбища'   = '80'
}

function Get-Page {
    <#
        Архив придушивает серии запросов: отдаёт 200 с нулём байт.
        Лечится паузой и повтором, поэтому проверяем, что в ответе
        действительно есть разметка выдачи. Пишем в память, а не во временный
        файл — на забитом диске это лишняя точка отказа.
    #>
    param([string]$Uri, [int]$Retries = 4)

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $body = (& curl.exe -s -L -m 90 -A $UserAgent $Uri) -join "`n"
        if ($body.Length -gt 5000) { return $body }
        Write-Verbose "Ответ пустой ($($body.Length) знаков), пауза и повтор $attempt из $Retries"
        Start-Sleep -Seconds (5 * $attempt)
    }
    throw "архив не отдал страницу за $Retries попыток: $Uri"
}

function Get-Field {
    # Значение лежит во втором <div> блока: первый — подпись для мобильной вёрстки
    param([string]$Block, [string]$Name)
    $m = [regex]::Match($Block, '(?s)<div class="\s*' + $Name + '">.*?<div class="mobile_title">.*?</div>\s*<div>(.*?)</div>')
    if (-not $m.Success) { return '' }
    $v = [Net.WebUtility]::HtmlDecode(($m.Groups[1].Value -replace '<[^>]+>', ' '))
    return ($v -replace '\s+', ' ').Trim()
}

$encoded = [uri]::EscapeDataString($Term)
$rows = @()

for ($page = 1; $page -le $MaxPages; $page++) {
    $uri = '{0}/book_search/?placeToSearch={1}&title={2}' -f $root, $codes[$Section], $encoded
    if ($page -gt 1) { $uri += "&page=page-$page" }

    $html = Get-Page $uri

    if ($page -eq 1) {
        $plain = [regex]::Replace($html, '<[^>]+>', ' ')
        $plain = [Net.WebUtility]::HtmlDecode($plain) -replace '\s+', ' '
        if ($plain -match 'Найдено:\s*([\d\s]+)результат') {
            Write-Host ("Найдено дел: " + $Matches[1].Trim()) -ForegroundColor Green
        }
        if ($plain -match 'Ничего не найдено') {
            Write-Warning "По запросу «$Term» в разделе «$Section» ничего нет."
            return
        }
    }

    $blocks = [regex]::Matches($html, '(?s)<div class="reports-list-item">.*?(?=<div class="reports-list-item">|<!-- /data -->|$)')
    if ($blocks.Count -eq 0) { break }

    foreach ($b in $blocks) {
        $block = $b.Value
        $link = [regex]::Match($block, 'href="(/metric-books/[^"]+)"')
        if (-not $link.Success) { continue }

        $desc = Get-Field $block 'UF_DESC'
        # В заголовке подшивки наш приход идёт под своим номером — вытащим его,
        # иначе в деле на 400 листов непонятно, куда листать
        $pos = ''
        $pm = [regex]::Match($desc, '(\d+)\s+[^\d]{0,40}' + [regex]::Escape($Term))
        if ($pm.Success) { $pos = $pm.Groups[1].Value }

        $rows += [pscustomobject]@{
            Фонд     = Get-Field $block 'UF_FOND'
            Опись    = Get-Field $block 'UF_OPIS'
            Дело     = Get-Field $block 'UF_DELO'
            Годы     = Get-Field $block 'UF_YEARS'
            Позиция  = $pos
            Описание = $desc.Substring(0, [Math]::Min(300, $desc.Length))
            Ссылка   = $root + $link.Groups[1].Value
        }
    }

    if ($blocks.Count -lt 10) { break }
    Start-Sleep -Milliseconds $DelayMs
}

# Фильтр по пересечению с заданным диапазоном
if ($YearFrom -or $YearTo) {
    $from = if ($YearFrom) { $YearFrom } else { 0 }
    $to = if ($YearTo) { $YearTo } else { 9999 }
    $rows = $rows | Where-Object {
        $ys = [regex]::Matches($_.Годы, '\d{4}') | ForEach-Object { [int]$_.Value }
        if (-not $ys) { return $false }
        $a = ($ys | Measure-Object -Minimum).Minimum
        $b = ($ys | Measure-Object -Maximum).Maximum
        $a -le $to -and $b -ge $from
    }
}

if ($rows.Count -eq 0) {
    Write-Warning 'После фильтра по годам ничего не осталось.'
    return
}

Write-Host "Отобрано: $($rows.Count)" -ForegroundColor Green
if ($OutCsv) {
    $rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Сохранено: $OutCsv" -ForegroundColor Green
}

$rows | Select-Object Фонд, Опись, Дело, Годы, Позиция, Ссылка | Format-Table -AutoSize
