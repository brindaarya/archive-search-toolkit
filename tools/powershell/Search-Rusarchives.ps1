<#
.SYNOPSIS
    Поиск следов усадьбы Быково по открытым архивным и документальным ресурсам.

.DESCRIPTION
    Обходит три источника, где не нужна регистрация:

      guides  — guides.rusarchives.ru, сводная база путеводителей по российским
                архивам. Полнотекст по аннотациям фондов и описей: показывает
                состав описи там, где сама опись нигде не выложена.
      istmat  — istmat.org, открытый корпус советских документов.
      sovdoc  — sovdoc.rusarchives.ru, «Документы советской эпохи» (протоколы
                Политбюро и др.). Работает через /api/public/search. На 4 августа
                2026 backend отвечал 500 «There are not living connections» —
                скрипт это переживает и просто помечает источник как недоступный.

    Каждая находка получает пометку привязки к усадьбе — «да» / «вероятно» /
    «нет данных». Пометка проставляется по явным признакам в тексте, а не по
    соседству в выдаче: при станции Быково всегда работало несколько учреждений
    сразу, и «в Быкове» само по себе усадьбу не означает.

.PARAMETER Query
    Свой список запросов вместо словаря по умолчанию.

.PARAMETER IncludeSecondary
    Добавить запросы второго эшелона (Бронницкий уезд — актуален только для
    1918–1924, дальше это уже Раменский район).

.PARAMETER Source
    Ограничить обход: guides, istmat, sovdoc. По умолчанию все три.

.PARAMETER Deep
    Догружать страницу каждой находки, чтобы получить контекст и точную
    пометку привязки. Медленнее, но без этого привязка почти всегда
    «нет данных» — в выдаче виден только заголовок.

.EXAMPLE
    .\Search-Rusarchives.ps1 -Deep
    Полный прогон по словарю с догрузкой контекста.

.EXAMPLE
    .\Search-Rusarchives.ps1 -Query 'дом отдыха','Марьино' -Source guides -Deep
#>
[CmdletBinding()]
param(
    [string[]]$Query,
    [switch]$IncludeSecondary,
    [ValidateSet('guides', 'istmat', 'sovdoc')]
    [string[]]$Source = @('guides', 'istmat', 'sovdoc'),
    [switch]$Deep,
    [string]$OutCsv = 'bykovo-rusarchives.csv',
    [int]$MaxPages = 5,
    [int]$MaxHitsPerQuery = 60,
    [int]$DelayMs = 700
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# У guides.rusarchives.ru неполная цепочка сертификатов — curl её тоже не проверяет.
# Гасим проверку только на время работы скрипта.
if (-not ('CertBypass' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public static class CertBypass {
    public static void Enable() {
        ServicePointManager.ServerCertificateValidationCallback =
            delegate (object s, X509Certificate c, X509Chain ch, System.Net.Security.SslPolicyErrors e) { return true; };
    }
}
'@
}
[CertBypass]::Enable()

$script:UserAgent = 'Search-Rusarchives.ps1/1.0 (personal archive research)'

$script:GuidesRoot = 'https://guides.rusarchives.ru'
$script:IstmatRoot = 'https://istmat.org'
$script:SovdocApi  = 'https://sovdoc.rusarchives.ru/api/public/search'

# Словарь по умолчанию. «дом отдыха» намеренно без номера: у разных ведомств
# своя нумерация, и наш «№ 4» — это нумерация того ведомства, которое мы ищем.
$script:PrimaryQueries = @(
    'Быково'
    'Верея'
    'Марьино'
    'Колонец'
    'Воронцов-Дашков'
    'дом отдыха'
    'Раменский'
)

$script:SecondaryQueries = @('Бронницкий')

# ---------------------------------------------------------------- HTTP

function Get-Utf8Response {
    param([string]$Uri, [int]$Retries = 3, [switch]$Json)

    $ProgressPreference = 'SilentlyContinue'
    $headers = @{}
    if ($Json) { $headers['Accept'] = 'application/json' }

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60 `
                -UserAgent $script:UserAgent -Headers $headers

            # Часть площадок не отдаёт charset — декодируем UTF-8 сами, иначе кириллица бьётся
            return [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        } catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }

            # 500 от sovdoc — это лежащий backend, повторять смысла нет
            if ($status -ge 500 -and $status -lt 600) {
                throw [InvalidOperationException]::new("HTTP $status")
            }
            if ($attempt -eq $Retries) { throw }
            Write-Verbose "Сеть подвела ($($_.Exception.Message)), попытка $($attempt + 1) из $Retries"
            Start-Sleep -Seconds ($attempt * 3)
        }
    }
}

function ConvertFrom-Html {
    param([string]$Text)
    if (-not $Text) { return '' }
    $s = $Text -replace '(?s)<script.*?</script>', ' '
    $s = $s -replace '(?s)<style.*?</style>', ' '
    $s = $s -replace '<[^>]+>', ' '
    $s = [Net.WebUtility]::HtmlDecode($s)
    return ($s -replace '\s+', ' ').Trim()
}

# ---------------------------------------------------------------- привязка

# Явные адресные признаки усадьбы. Ничего из этого не может относиться
# к другим учреждениям при станции Быково.
$script:StrongMarkers = @(
    'Воронцов', 'Дашков', 'Измайлов', 'Марьино', 'Колонец',
    'усадьб', 'дворец', 'дворца', 'имени?[ия]\s+быв', 'дача\s+быв',
    'инженера\s+Ильин', 'Ильиной', 'Баженов'
)

# Учрежденческие слова: сами по себе усадьбу не доказывают, но в паре
# с топонимом дают «вероятно»
$script:InstitutionMarkers = @(
    'дом\s+отдыха', 'домов\s+отдыха', 'санатор', 'колони', 'детский\s+дом',
    'здравниц', 'ОГПУ', 'НКВД', 'ГПУ', 'спецотдел', 'госпитал'
)

$script:ToponymMarkers = @('Быков', 'Верея', 'Верейск', 'Раменск', 'Бронниц')

# Отсев шума: «Быкова Э. Б.», «Быков Василий Иванович» — это фамилии,
# а не наш топоним. Полнотекст guides матчит по основе слова и тащит их пачками.
$script:PersonNoise = '(Быков|Быкова|Быкове[рв])\s*(?:[А-Я]\.\s*[А-Я]?\.?|[А-Я][а-я]+\s+[А-Я][а-я]+ич)'

# Основа слова для поиска вхождений: ищем «Быков» внутри «Быково/Быкове/Быковский».
# Без этого пришлось бы перечислять все падежи руками.
$script:Stems = @{
    'Быково'          = 'Быков'
    'Верея'           = 'Вере[йя]'
    'Марьино'         = 'Марьин'
    'Колонец'         = 'Колон[ec]ц'
    'Воронцов-Дашков' = 'Воронцов'
    'Раменский'       = 'Раменск'
    'Бронницкий'      = 'Бронниц'
    'дом отдыха'      = 'дом\w*\s+отдыха'
}

function Get-Stem {
    param([string]$Term)
    if ($script:Stems.ContainsKey($Term)) { return $script:Stems[$Term] }
    # Отсекаем типовое окончание, чтобы поймать падежи
    return [regex]::Escape(($Term -replace '(ое|ий|ый|ая|о|а|е)$', ''))
}

function Get-ContextWindows {
    <#
        Окна вокруг каждого вхождения термина. Привязку считаем только по окну:
        на длинной странице путеводителя «Быков» и «усадьба» встречаются
        в совершенно разных фондах, и оценка по всему тексту даёт ложное «да».
    #>
    param([string]$Text, [string]$Term, [int]$Radius = 300)

    if (-not $Text) { return @() }
    $rx = Get-Stem $Term

    $windows = @()
    foreach ($m in [regex]::Matches($Text, $rx, 'IgnoreCase')) {
        $start = [Math]::Max(0, $m.Index - $Radius)
        $len = [Math]::Min($Radius * 2, $Text.Length - $start)
        $windows += $Text.Substring($start, $len)
        if ($windows.Count -ge 12) { break }
    }

    if ($windows.Count -eq 0) {
        $windows = @($Text.Substring(0, [Math]::Min(400, $Text.Length)))
    }
    return $windows
}

function Test-AnyMatch {
    param([string]$Text, [string[]]$Patterns)
    foreach ($p in $Patterns) {
        if ($Text -match $p) { return $true }
    }
    return $false
}

function Get-Binding {
    <#
        Возвращает пометку привязки к усадьбе и короткое обоснование.
        Правило намеренно консервативное: «да» только при явном адресном
        признаке, иначе максимум «вероятно».
    #>
    param([string]$Text)

    if (-not $Text) {
        return [pscustomobject]@{ Binding = 'нет данных'; Signal = '' }
    }

    $hasStrong = Test-AnyMatch -Text $Text -Patterns $script:StrongMarkers
    $hasTopo   = Test-AnyMatch -Text $Text -Patterns $script:ToponymMarkers
    $hasInst   = Test-AnyMatch -Text $Text -Patterns $script:InstitutionMarkers

    $signals = @()
    foreach ($p in ($script:StrongMarkers + $script:InstitutionMarkers)) {
        $m = [regex]::Match($Text, $p, 'IgnoreCase')
        if ($m.Success) { $signals += $m.Value }
    }
    $signal = ($signals | Select-Object -Unique -First 5) -join '; '

    if ($hasStrong -and $hasTopo) {
        return [pscustomobject]@{ Binding = 'да'; Signal = $signal }
    }
    if ($hasStrong) {
        return [pscustomobject]@{ Binding = 'вероятно'; Signal = $signal }
    }
    if ($hasTopo -and $hasInst) {
        return [pscustomobject]@{ Binding = 'вероятно'; Signal = $signal }
    }

    # Только фамилия и ничего больше — почти наверняка мусор в выдаче
    if ($Text -match $script:PersonNoise -and -not $hasInst) {
        return [pscustomobject]@{ Binding = 'нет данных'; Signal = 'похоже на фамилию' }
    }

    return [pscustomobject]@{ Binding = 'нет данных'; Signal = $signal }
}

# ---------------------------------------------------------------- источники

function Search-Guides {
    param([string]$Term)

    $results = @()
    for ($page = 0; $page -lt $MaxPages; $page++) {
        $uri = '{0}/search?search_api_views_fulltext={1}&page={2}' -f `
            $script:GuidesRoot, [uri]::EscapeDataString($Term), $page

        $html = Get-Utf8Response -Uri $uri
        $matches = [regex]::Matches($html, '<a href="(/node/\d+)"[^>]*>(.*?)</a>', 'Singleline')
        if ($matches.Count -eq 0) { break }

        foreach ($m in $matches) {
            $results += [pscustomobject]@{
                Url   = $script:GuidesRoot + $m.Groups[1].Value
                Title = ConvertFrom-Html $m.Groups[2].Value
            }
        }

        if ($results.Count -ge $MaxHitsPerQuery) { break }
        Start-Sleep -Milliseconds $DelayMs
    }

    return $results | Select-Object -Unique -First $MaxHitsPerQuery -Property Url, Title
}

function Search-Istmat {
    param([string]$Term)

    $uri = '{0}/search/node/{1}' -f $script:IstmatRoot, [uri]::EscapeDataString($Term)
    $html = Get-Utf8Response -Uri $uri

    $results = @()
    $matches = [regex]::Matches($html, '(?s)<h3[^>]*class="title"[^>]*>\s*<a href="([^"]+)"[^>]*>(.*?)</a>.*?(?:<p class="search-snippet">(.*?)</p>)?')
    foreach ($m in $matches) {
        $url = $m.Groups[1].Value
        if ($url -notmatch '^https?://') { $url = $script:IstmatRoot + $url }
        $results += [pscustomobject]@{
            Url     = $url
            Title   = ConvertFrom-Html $m.Groups[2].Value
            Snippet = ConvertFrom-Html $m.Groups[3].Value
        }
    }
    return $results | Select-Object -First $MaxHitsPerQuery
}

function Search-Sovdoc {
    param([string]$Term)

    $uri = '{0}?title={1}&limit={2}' -f $script:SovdocApi, [uri]::EscapeDataString($Term), $MaxHitsPerQuery
    try {
        $body = Get-Utf8Response -Uri $uri -Json -Retries 1
    } catch [InvalidOperationException] {
        Write-Warning "sovdoc недоступен ($($_.Exception.Message)) — backend лежит на их стороне, пропускаю"
        $script:SovdocDown = $true
        return @()
    }

    $obj = $body | ConvertFrom-Json
    $items = $obj.items
    if (-not $items) { $items = $obj.data }
    if (-not $items) { return @() }

    $results = @()
    foreach ($it in $items) {
        $results += [pscustomobject]@{
            Url     = 'https://sovdoc.rusarchives.ru/details/' + $it.id
            Title   = $it.title
            Snippet = $it.annotation
        }
    }
    return $results
}

# ---------------------------------------------------------------- прогон

if (-not $Query) {
    $Query = $script:PrimaryQueries
    if ($IncludeSecondary) { $Query += $script:SecondaryQueries }
}

$script:SovdocDown = $false
$rows = @()
$seen = @{}

foreach ($term in $Query) {
    foreach ($src in $Source) {

        Write-Host "[$src] $term" -ForegroundColor Cyan
        $hits = @()
        try {
            switch ($src) {
                'guides' { $hits = Search-Guides -Term $term }
                'istmat' { $hits = Search-Istmat -Term $term }
                'sovdoc' {
                    if ($script:SovdocDown) { continue }
                    $hits = Search-Sovdoc -Term $term
                }
            }
        } catch {
            Write-Warning "[$src] $term — $($_.Exception.Message)"
            continue
        }

        $hits = @($hits)
        Write-Host "    найдено: $($hits.Count)" -ForegroundColor DarkGray

        foreach ($h in $hits) {
            $key = $src + '|' + $h.Url
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $context = $h.Title
            if ($h.PSObject.Properties['Snippet'] -and $h.Snippet) {
                $context += ' ' + $h.Snippet
            }

            # Без догрузки страницы у guides виден только заголовок, а вся
            # аннотация описи — внутри узла. Привязку иначе не определить.
            if ($Deep -and $src -eq 'guides') {
                try {
                    Start-Sleep -Milliseconds $DelayMs
                    $page = Get-Utf8Response -Uri $h.Url
                    $context = ConvertFrom-Html $page
                } catch {
                    Write-Verbose "не догрузил $($h.Url): $($_.Exception.Message)"
                }
            }

            # Привязку берём по лучшему окну, а не по всему документу
            $rank = @{ 'да' = 2; 'вероятно' = 1; 'нет данных' = 0 }
            $b = [pscustomobject]@{ Binding = 'нет данных'; Signal = '' }
            $snippet = ''

            foreach ($w in (Get-ContextWindows -Text $context -Term $term)) {
                $cand = Get-Binding -Text $w
                if ($rank[$cand.Binding] -gt $rank[$b.Binding]) {
                    $b = $cand
                    $snippet = $w
                }
            }

            if (-not $snippet) {
                $first = @(Get-ContextWindows -Text $context -Term $term)[0]
                if ($first) { $snippet = $first }
            }
            $snippet = $snippet.Substring(0, [Math]::Min(320, $snippet.Length))

            $rows += [pscustomobject]@{
                Source   = $src
                Query    = $term
                Title    = $h.Title
                Url      = $h.Url
                Binding  = $b.Binding
                Signal   = $b.Signal
                Snippet  = $snippet
            }
        }

        Start-Sleep -Milliseconds $DelayMs
    }
}

# ---------------------------------------------------------------- вывод

if ($rows.Count -eq 0) {
    Write-Warning 'Ничего не найдено.'
    return
}

$order = @{ 'да' = 0; 'вероятно' = 1; 'нет данных' = 2 }
$rows = $rows | Sort-Object @{ Expression = { $order[$_.Binding] } }, Source, Query

$rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host "Всего записей: $($rows.Count)" -ForegroundColor Green
$rows | Group-Object Binding | Sort-Object { $order[$_.Name] } | ForEach-Object {
    Write-Host ("  привязка {0,-12} {1}" -f $_.Name, $_.Count)
}
Write-Host "Сохранено: $OutCsv" -ForegroundColor Green

if ($script:SovdocDown) {
    Write-Host ''
    Write-Warning 'sovdoc.rusarchives.ru не отвечал — прогнать этот источник отдельно, когда поднимется: -Source sovdoc'
}

$rows | Where-Object { $_.Binding -ne 'нет данных' } |
    Select-Object Binding, Source, Query, Title, Url |
    Format-Table -AutoSize -Wrap
