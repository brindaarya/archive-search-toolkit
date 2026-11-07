<#
.SYNOPSIS
    Выгрузка страниц-сканов с площадок на платформе «ИнфоРост»:
    elib.shpl.ru (ГПИБ) и docs.historyrussia.org («Исторические материалы»).

.DESCRIPTION
    Раньше это был Get-ShplPage.ps1 только под ГПИБ. Разница между площадками
    ровно в двух вещах: корневой адрес и то, что docs.historyrussia.org
    требует `--http1.1 --compressed`, иначе обрывает передачу примерно
    на 15 КБ и висит до таймаута.

    Просмотрщик Docview получает список страниц прямо в HTML узла, вызовом
    initDocview({...,"pages":[{"id":1735914,...},...]}). Идентификаторы идут
    подряд, поэтому достаточно взять первый: id страницы N = первый + N - 1.
    Картинка лежит по /pages/<id>/zooms/<z>.

    Уровни увеличения — 0..8, каждый примерно в полтора раза крупнее
    предыдущего, последний шаг сразу вдвое: 0 даёт 82x104, 4 — 656x829,
    8 — 1966x2485. Для обычного текста хватает 4, для мелкого набора
    в колонку (адрес-календари) нужен 8.

    Номер страницы — номер скана из ссылки #mode/inspect/page/N,
    а не типографская пагинация; они обычно расходятся на несколько листов.

.EXAMPLE
    .\Get-InforostPage.ps1 -NodeId 438361 -Page 1,2 -Root 'https://docs.historyrussia.org'

.EXAMPLE
    .\Get-InforostPage.ps1 -NodeId 27332 -Page 18 -Zoom 8 -Prefix 'ВсяМосква-1904'

.EXAMPLE
    .\Get-InforostPage.ps1 -NodeId 438361 -All -Root 'https://docs.historyrussia.org'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$NodeId,
    [int[]]$Page,
    # Забрать все сканы узла — для коротких документов удобнее, чем перечислять
    [switch]$All,
    [string]$Root = 'http://elib.shpl.ru',
    [string]$OutDir = 'сканы',
    [string]$Prefix = '',
    [ValidateRange(0, 8)][int]$Zoom = 4
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$UserAgent = 'Get-InforostPage.ps1/1.0 (personal archive research)'

if (-not $Page -and -not $All) {
    throw 'Укажите -Page с номерами страниц или -All, чтобы забрать узел целиком.'
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

function Get-Body {
    param([string]$Uri)
    $tmp = Join-Path $env:TEMP ('inforost_' + [Guid]::NewGuid().ToString('N') + '.html')
    try {
        & curl.exe -s -L --http1.1 --compressed -m 90 -A $UserAgent -o $tmp $Uri
        if (-not (Test-Path $tmp)) { throw "пустой ответ: $Uri" }
        return [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

function Save-Chunked {
    <#
        docs.historyrussia.org обрывает любой ответ примерно на 15 КБ.
        Для HTML это лечится gzip, но скан — уже сжатый JPEG на сотни килобайт,
        и сжимать нечего. Зато сервер объявляет Accept-Ranges: bytes,
        поэтому берём файл кусками по 10 КБ и склеиваем.

        На ГПИБ ограничения нет, и там это просто лишние запросы — поэтому
        сначала пробуем скачать целиком и уходим в докачку только при обрыве.
    #>
    param([string]$Uri, [string]$Path, [int]$ChunkSize = 10000)

    # Всюду -s, а не -sS: PowerShell 5.1 превращает любой вывод curl в stderr
    # в терминирующую ошибку, и при $ErrorActionPreference='Stop' скрипт падает
    # на первом же оборванном ответе. Об успехе судим по размеру файла.
    # Ожидаемый размер обязателен: без него нельзя отличить целый файл
    # от оборванного. Запрос заголовков тоже иногда срывается, поэтому повторяем.
    $expected = 0
    for ($try = 1; $try -le 3 -and $expected -eq 0; $try++) {
        $head = & curl.exe -s -I --http1.1 -m 45 -A $UserAgent $Uri
        foreach ($line in $head) {
            if ($line -match '(?i)^Content-Length:\s*(\d+)') { $expected = [int]$Matches[1] }
        }
        if ($expected -eq 0) { Start-Sleep -Milliseconds (500 * $try) }
    }
    if ($expected -eq 0) {
        throw "не удалось узнать размер файла, качать вслепую нельзя: $Uri"
    }

    # Короткий пробник: на ГПИБ файл придёт целиком и докачка не понадобится,
    # на docs.historyrussia.org оборвётся секунды за две.
    & curl.exe -s -L --http1.1 -m 30 -A $UserAgent -o $Path $Uri

    if ((Test-Path $Path) -and (Get-Item $Path).Length -ge $expected) { return }

    Write-Verbose "Ответ оборван, добираю кусками по $ChunkSize б (всего $expected)"
    $stream = [IO.File]::Create($Path)
    try {
        for ($from = 0; $from -lt $expected; $from += $ChunkSize) {
            $to = [Math]::Min($from + $ChunkSize - 1, $expected - 1)
            $part = Join-Path $env:TEMP ('chunk_' + [Guid]::NewGuid().ToString('N') + '.bin')
            try {
                # Отдельные куски иногда не приходят — сервер срывается
                # на ровном месте, со второй попытки отдаёт нормально
                $bytes = $null
                for ($try = 1; $try -le 5; $try++) {
                    & curl.exe -s --http1.1 -m 60 -A $UserAgent -H "Range: bytes=$from-$to" -o $part $Uri
                    if ((Test-Path $part) -and (Get-Item $part).Length -eq ($to - $from + 1)) {
                        $bytes = [IO.File]::ReadAllBytes($part)
                        break
                    }
                    Start-Sleep -Milliseconds (400 * $try)
                }
                if ($null -eq $bytes) { throw "не пришёл кусок $from-$to после 5 попыток" }
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                Remove-Item $part -ErrorAction SilentlyContinue
            }
        }
    } finally {
        $stream.Close()
    }
}

$html = Get-Body "$Root/ru/nodes/$NodeId"

$m = [regex]::Match($html, '"pages":\[\{"id":(\d+)')
if (-not $m.Success) {
    throw "В узле $NodeId не нашёлся список страниц — возможно, у него нет сканов."
}
$firstId = [int]$m.Groups[1].Value
$total = ([regex]::Matches($html, '"id":\d+,"w":')).Count

$title = ''
$tm = [regex]::Match($html, '(?s)<title>(.*?)</title>')
if ($tm.Success) { $title = [Net.WebUtility]::HtmlDecode($tm.Groups[1].Value).Trim() }

Write-Host "Узел $NodeId : $title" -ForegroundColor Cyan
Write-Host "  первая страница id=$firstId, всего сканов: $total" -ForegroundColor DarkGray

if ($All) { $Page = 1..$total }

foreach ($n in $Page) {
    if ($n -lt 1 -or ($total -and $n -gt $total)) {
        Write-Warning "  стр. $n — вне диапазона (в узле $total сканов), пропускаю"
        continue
    }
    $id = $firstId + $n - 1
    $name = if ($Prefix) { '{0}-стр{1:d3}.jpg' -f $Prefix, $n } else { 'node{0}-стр{1:d3}.jpg' -f $NodeId, $n }
    $path = Join-Path $OutDir $name

    Save-Chunked -Uri "$Root/pages/$id/zooms/$Zoom" -Path $path

    if (Test-Path $path) {
        $size = (Get-Item $path).Length
        if ($size -lt 3000) {
            Write-Warning "  стр. $n — файл подозрительно мал ($size б)"
        } else {
            Write-Host ("  стр. {0,-4} -> {1} ({2:N0} б)" -f $n, $name, $size)
        }
    } else {
        Write-Warning "  стр. $n — не скачалась"
    }
    Start-Sleep -Milliseconds 500
}
