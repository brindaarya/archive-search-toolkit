<#
.SYNOPSIS
    Поиск по электронным библиотекам на платформе «ИнфоРост» — сейчас это
    docs.historyrussia.org («Исторические материалы») и elib.shpl.ru (ГПИБ).

.DESCRIPTION
    Обобщение Search-Shpl.ps1: разбор выдачи у обеих площадок одинаковый,
    различается только корневой адрес и словарь запросов.

    Осторожно с docs.historyrussia.org: главная страница у них отдаёт первые
    ~15 КБ и виснет намертво, полностью её получить не удаётся. Поиск при этом
    отвечает за секунду. Поэтому обход идёт только через /ru/nodes/search,
    к дереву узлов не обращаемся.

    Привязка считается по куску OCR вокруг попадания, отдельно для каждой темы:
    у философа Ильина и у быковского дома отдыха общего нет ничего, и единый
    набор маркеров тут только мешает.

.PARAMETER Theme
    философ | быковские | усадьба. По умолчанию все три.

.PARAMETER Root
    Корень площадки. По умолчанию docs.historyrussia.org.

.EXAMPLE
    .\Search-Inforost.ps1 -Theme философ

.EXAMPLE
    .\Search-Inforost.ps1 -Root 'http://elib.shpl.ru' -Query '+Ильин* +Бронницк*'
#>
[CmdletBinding()]
param(
    [ValidateSet('философ', 'быковские', 'усадьба')]
    [string[]]$Theme,
    [string[]]$Query,
    [string]$Root = 'https://docs.historyrussia.org',
    [string]$OutCsv = 'ilyin-historyrussia.csv',
    [int]$MaxPages = 8,
    # Больше десятка на страницу этот сервер не отдаёт: обрывает передачу
    # примерно на 15 КБ. Порог плавает — 20 иногда проходит, 30 уже нет.
    [int]$PerPage = 10,
    [int]$MaxHitsPerNode = 6,
    # Площадка хрупкая, частим осторожно
    [int]$DelayMs = 1200
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:UserAgent = 'Search-Inforost.ps1/1.0 (personal archive research)'

# ---------------------------------------------------------------- темы

# Для каждой темы: запросы, «сильные» признаки (дают «да») и «слабые» («вероятно»).
# Признаки проверяются по окну OCR, которое площадка отдаёт прямо в выдаче.
$script:Themes = [ordered]@{

    'философ' = @{
        # Иван Александрович Ильин (1883–1954), высылка 1922 г.
        Queries = @(
            '"Иван Александрович Ильин"~4'
            '"Ильин Иван Александрович"~4'
            '+Ильин +философ*'
            '+Ильин +высылк*'
            '+Ильин +ГПУ'
            '+Ильин +профессор*'
        )
        Strong = @(
            'Иван\w*\s+Александрович\w*\s+Ильин', 'Ильин\w*,?\s+Иван\w*\s+Александрович',
            'И\.\s*А\.\s*Ильин', 'Ильин\w*\s+И\.\s*А\.',
            'Ильин\w{0,3}[^.]{0,60}философ', 'философ[^.]{0,60}Ильин'
        )
        Weak = @(
            'Ильин\w{0,3}[^.]{0,80}(?:ГПУ|ВЧК|ОГПУ|высылк|выслан|аресто|допрос|антисоветск)',
            'Ильин\w{0,3}[^.]{0,80}(?:профессор|приват-доцент|университет)'
        )
    }

    'быковские' = @{
        # Н. И. Ильин (1837–1907), Е. А. Ильина (1850–1923),
        # А. Н. Ильин (1872–1927/28), М. А. Ильин (1903–1981)
        Queries = @(
            '+Ильин +Бронниц*'
            '+Ильин +Быков*'
            '"Ильина Екатерина Андреевна"~4'
            '"Ильин Андрей Николаевич"~4'
            '"Ильин Михаил Андреевич"~4'
        )
        Strong = @(
            'Ильин\w{0,3}[^.]{0,80}(?:Бронниц|Быков[ое]\b|Раменск)',
            '(?:Бронниц|Быков[ое]\b|Раменск)[^.]{0,80}Ильин',
            'Ильин\w*\s+Андрей\w*\s+Николаевич', 'Ильин\w*,?\s+Михаил\w*\s+Андреевич',
            'Ильин\w*\s+Екатерин\w*\s+Андреевн', 'Ильин\w*\s+Николай\w*\s+Иванович'
        )
        Weak = @(
            'Ильин\w{0,3}[^.]{0,80}(?:земск|усадьб|имени[ея]|volost|волост)'
        )
    }

    'усадьба' = @{
        # Быково XX века: дом отдыха, спецшкола, санаторий
        Queries = @(
            '+Быков* +"дом отдыха"'
            '+Быков* +санатор*'
            '+Быков* +усадьб*'
            '+Быков* +Раменск*'
            '+Быков* +Бронниц*'
        )
        Strong = @(
            'Быков[ое]\b[^.]{0,90}(?:усадьб|дворец|дом\w*\s+отдыха|санатор|Воронцов|Шмидт|МОСПС)',
            '(?:усадьб|дворец|дом\w*\s+отдыха|санатор|Воронцов|Шмидт|МОСПС)[^.]{0,90}Быков[ое]\b',
            'Быков[ое]\b[^.]{0,60}(?:Бронниц|Раменск)'
        )
        Weak = @(
            'Быков[ое]\b[^.]{0,90}(?:волост|станц|школ|колони|детск)'
        )
    }
}

# Фамилия, а не топоним: «Быков А. Ф.», «Быкову Ивану Петровичу».
# В советском делопроизводстве этого добра особенно много.
$script:PersonNoise = 'Быков[аеуы]?м?\w{0,2}\s*(?:[А-Я]\.\s*[А-Я]?\.?|[А-Я][а-я]+\s+[А-Я][а-я]+(?:ич|вна))'

# ---------------------------------------------------------------- HTTP

function Get-Utf8Response {
    <#
        Через curl, а не Invoke-WebRequest, и обязательно с `--http1.1 --compressed`.
        Без этих двух флагов docs.historyrussia.org отдаёт первые ~15 КБ и виснет
        до таймаута: и обычный HTTP/2, и голый HTTP/1.1, и один только gzip
        обрываются одинаково, работает только сочетание. Invoke-WebRequest
        управлять этим не умеет и просто висит.

        Обрыв всё равно случается на больших ответах, поэтому каждый ответ
        проверяем на закрывающий тег и при обрыве повторяем.
    #>
    param([string]$Uri, [int]$Retries = 4)

    $tmp = Join-Path $env:TEMP ('inforost_' + [Guid]::NewGuid().ToString('N') + '.html')
    try {
        for ($attempt = 1; $attempt -le $Retries; $attempt++) {
            & curl.exe -sSL --http1.1 --compressed -m 60 -A $script:UserAgent -o $tmp $Uri 2>$null | Out-Null

            if (Test-Path $tmp) {
                $body = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
                if ($body.TrimEnd().EndsWith('</html>')) { return $body }
                Write-Verbose "Ответ оборван на $($body.Length) знаках, повтор $($attempt + 1) из $Retries"
            }

            if ($attempt -eq $Retries) {
                throw "не удалось получить ответ целиком за $Retries попыток: $Uri"
            }
            Start-Sleep -Seconds ($attempt * 3)
        }
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-Html {
    param([string]$Text)
    if (-not $Text) { return '' }
    $s = $Text -replace '(?s)<script.*?</script>', ' '
    $s = $s -replace '(?s)<style.*?</style>', ' '
    $s = $s -replace '<br\s*/?>', ' '
    $s = $s -replace '<[^>]+>', ' '
    $s = [Net.WebUtility]::HtmlDecode($s)
    return ($s -replace '\s+', ' ').Trim()
}

# ---------------------------------------------------------------- привязка

function Test-AnyMatch {
    param([string]$Text, [string[]]$Patterns)
    foreach ($p in $Patterns) {
        if ($Text -match $p) { return $true }
    }
    return $false
}

function Get-Signal {
    param([string]$Text, [string[]]$Patterns)
    $found = @()
    foreach ($p in $Patterns) {
        $m = [regex]::Match($Text, $p, 'IgnoreCase')
        if ($m.Success) {
            $v = $m.Value
            if ($v.Length -gt 70) { $v = $v.Substring(0, 70) }
            $found += $v
        }
    }
    return ($found | Select-Object -Unique -First 3) -join ' ; '
}

function Get-Binding {
    param([string]$Text, [hashtable]$Rules)

    if (-not $Text) {
        return [pscustomobject]@{ Binding = 'нет данных'; Signal = '' }
    }

    if (Test-AnyMatch -Text $Text -Patterns $Rules.Strong) {
        return [pscustomobject]@{
            Binding = 'да'
            Signal  = Get-Signal -Text $Text -Patterns $Rules.Strong
        }
    }
    if (Test-AnyMatch -Text $Text -Patterns $Rules.Weak) {
        return [pscustomobject]@{
            Binding = 'вероятно'
            Signal  = Get-Signal -Text $Text -Patterns $Rules.Weak
        }
    }
    if ($Text -match $script:PersonNoise) {
        return [pscustomobject]@{ Binding = 'нет данных'; Signal = 'похоже на фамилию Быков' }
    }
    return [pscustomobject]@{ Binding = 'нет данных'; Signal = '' }
}

# ---------------------------------------------------------------- разбор выдачи

function Get-Cells {
    param([string]$RowHtml)
    $cells = @()
    foreach ($m in [regex]::Matches($RowHtml, '(?s)<td[^>]*>(.*?)</td>')) {
        $cells += ConvertFrom-Html $m.Groups[1].Value
    }
    return $cells
}

function Search-Node {
    <#
        Пронумерованная строка — издание, следующие за ней безномерные
        «Страница N» — попадания в распознанный текст этого издания.
        Разбирать можно только последовательно.
    #>
    param([string]$Term)

    $results = @()
    $encoded = [uri]::EscapeDataString($Term)

    for ($page = 1; $page -le $MaxPages; $page++) {
        $uri = '{0}/ru/nodes/search?query={1}&search_in_metadata=on&search_in_texts=on&per_page={2}&page={3}' -f `
            $Root, $encoded, $PerPage, $page

        $html = Get-Utf8Response -Uri $uri
        $rows = [regex]::Matches($html, '(?s)<tr[^>]*>.*?</tr>')
        if ($rows.Count -le 1) { break }

        $current = $null
        $nodeHits = 0
        $found = 0

        foreach ($row in $rows) {
            $rowHtml = $row.Value
            if ($rowHtml -notmatch '<td') { continue }

            $link = [regex]::Match($rowHtml, 'href="(/ru/nodes/\d+[^"]*)"')
            if (-not $link.Success) { continue }

            $cells = Get-Cells $rowHtml

            if ($rowHtml -match "<td class='first'>\s*\d+\s*</td>") {
                $found++
                $nodeHits = 0
                $current = [pscustomobject]@{
                    Title  = $cells[1]
                    Url    = $Root + ($link.Groups[1].Value -replace '\?.*$', '')
                    Kind   = if ($cells.Count -gt 2) { $cells[2] } else { '' }
                    Year   = if ($cells.Count -gt 10) { $cells[10] } else { '' }
                    Parent = if ($cells.Count -gt 11) { $cells[11] } else { '' }
                }
                $results += [pscustomobject]@{
                    Title   = $current.Title
                    Url     = $current.Url
                    Kind    = $current.Kind
                    Year    = $current.Year
                    Parent  = $current.Parent
                    Page    = ''
                    Snippet = (($cells | Select-Object -Skip 1 -First 6) | Where-Object { $_ }) -join ' | '
                }
                continue
            }

            if ($current -and $nodeHits -lt $MaxHitsPerNode -and $cells[1] -match 'Страниц\w*\s*(\d+)') {
                $pageNo = $Matches[1]
                $nodeHits++
                $results += [pscustomobject]@{
                    Title   = $current.Title
                    Url     = $Root + $link.Groups[1].Value
                    Kind    = $current.Kind
                    Year    = $current.Year
                    Parent  = $current.Parent
                    Page    = $pageNo
                    Snippet = $cells[2]
                }
            }
        }

        if ($found -lt $PerPage) { break }
        Start-Sleep -Milliseconds $DelayMs
    }

    return $results
}

# ---------------------------------------------------------------- прогон

$plan = @()
if ($Query) {
    foreach ($q in $Query) { $plan += [pscustomobject]@{ Theme = 'свой запрос'; Q = $q } }
} else {
    $sets = if ($Theme) { $Theme } else { $script:Themes.Keys }
    foreach ($t in $sets) {
        foreach ($q in $script:Themes[$t].Queries) {
            $plan += [pscustomobject]@{ Theme = $t; Q = $q }
        }
    }
}

$rows = @()
$seen = @{}

foreach ($item in $plan) {
    Write-Host "[$($item.Theme)] $($item.Q)" -ForegroundColor Cyan

    $hits = @()
    try {
        $hits = @(Search-Node -Term $item.Q)
    } catch {
        Write-Warning "$($item.Q) — $($_.Exception.Message)"
        continue
    }
    Write-Host "    записей: $($hits.Count)" -ForegroundColor DarkGray

    $rules = if ($item.Theme -eq 'свой запрос') {
        @{ Strong = @('Ильин|Быков[ое]\b'); Weak = @() }
    } else {
        $script:Themes[$item.Theme]
    }

    foreach ($h in $hits) {
        $key = $item.Theme + '|' + $h.Url + '|' + $h.Page
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $b = Get-Binding -Text $h.Snippet -Rules $rules

        $rows += [pscustomobject]@{
            Theme   = $item.Theme
            Query   = $item.Q
            Binding = $b.Binding
            Signal  = $b.Signal
            Year    = $h.Year
            Title   = $h.Title
            Parent  = $h.Parent
            Page    = $h.Page
            Snippet = $h.Snippet.Substring(0, [Math]::Min(400, $h.Snippet.Length))
            Url     = $h.Url
        }
    }

    Start-Sleep -Milliseconds $DelayMs
}

# ---------------------------------------------------------------- вывод

if ($rows.Count -eq 0) {
    Write-Warning 'Ничего не найдено.'
    return
}

$order = @{ 'да' = 0; 'вероятно' = 1; 'нет данных' = 2 }
$rows = $rows | Sort-Object @{ Expression = { $order[$_.Binding] } }, Theme, Year
$rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host "Всего записей: $($rows.Count)" -ForegroundColor Green
$rows | Group-Object Binding | Sort-Object { $order[$_.Name] } | ForEach-Object {
    Write-Host ("  привязка {0,-12} {1}" -f $_.Name, $_.Count)
}
$rows | Where-Object { $_.Binding -ne 'нет данных' } | Group-Object Theme | ForEach-Object {
    Write-Host ("  тема {0,-14} {1}" -f $_.Name, $_.Count)
}
Write-Host "Сохранено: $OutCsv" -ForegroundColor Green
