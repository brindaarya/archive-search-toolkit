# ya-archive.ps1 — доступ к Яндекс Архиву (yandex.ru/archive) без браузера.
# Поиск отдаётся server-side рендерингом Next.js, поэтому весь результат
# лежит в <script id="__NEXT_DATA__"> и достаётся обычным Invoke-WebRequest.
# Ни Playwright, ни авторизация не нужны.
#
# Использование:
#   . .\ya-archive.ps1
#   Search-YaArchive -Text 'детская колония Быково' -Index mass_media -DateFrom 1918 -DateTo 1925
#   Get-YaPageText -NodeId '8cddf8a4-...' -Page 4

$script:YaHeaders = @{
    'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
    'Accept-Language' = 'ru-RU,ru;q=0.9'
}

function Get-YaNextData {
    param([Parameter(Mandatory)][string]$Url)

    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers $script:YaHeaders -TimeoutSec 90
    $m = [regex]::Match($resp.Content, '(?s)<script id="__NEXT_DATA__" type="application/json">(.*?)</script>')
    if (-not $m.Success) { throw "Не найден __NEXT_DATA__ на $Url" }
    $m.Groups[1].Value | ConvertFrom-Json
}

function Search-YaArchive {
    <#
      -Index: пусто = весь корпус (по умолчанию, ЦГА Москвы и «Русский архив» видны только так)
      mass_media (только узкая периодика) | archive (архивные дела) | books (справочники)
      -Fuzzy: включить неточное совпадение
      Годы задаются четырёхзначным числом (dateFrom/dateTo на стороне Яндекса).
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('', 'mass_media', 'archive', 'books')][string]$Index = '',
        [int]$DateFrom,
        [int]$DateTo,
        [switch]$Fuzzy,
        [int]$MaxPages = 5,
        [int]$DelayMs = 400
    )

    $qs = "text=$([uri]::EscapeDataString($Text))"
    if ($Index) { $qs += "&index=$Index" }
    if ($DateFrom) { $qs += "&dateFrom=$DateFrom" }
    if ($DateTo) { $qs += "&dateTo=$DateTo" }
    if ($Fuzzy) { $qs += '&fuzzy=1' }

    $pageNum = 1
    $total = $null

    while ($pageNum -le $MaxPages) {
        $url = "https://yandex.ru/archive/search?$qs&p=$pageNum"
        $pp = (Get-YaNextData -Url $url).props.pageProps
        if ($null -eq $total) { $total = $pp.totalDocs }
        if (-not $pp.items -or $pp.items.Count -eq 0) { break }

        foreach ($it in $pp.items) {
            [pscustomobject]@{
                Query    = $Text
                Index    = $Index
                Date     = $it.dateFrom
                DateTo   = $it.dateTo
                Source   = $it.namepath
                Snippet  = ($it.snippet -replace "`a\[", '«' -replace "`a\]", '»')
                NodeId   = $it.parentId
                Page     = $it.sheetPageNumber
                Url      = "https://yandex.ru/archive/catalog/$($it.parentId)/$($it.sheetPageNumber)"
                Total    = $total
            }
        }

        if ($pageNum -ge $pp.totalPages) { break }
        $pageNum++
        Start-Sleep -Milliseconds $DelayMs
    }
}

function Get-YaImage {
    <#
      Скан страницы. -Type preview — небольшая картинка без формальностей;
      -Type original — полное разрешение, для него сначала берётся подписанная
      ссылка через POST /archive/api/image-grant (живёт ~сутки).
      SheetId — это поле id самой страницы (не parentId!), см. Get-YaSheetId.
    #>
    param(
        [Parameter(Mandatory)][string]$SheetId,
        [Parameter(Mandatory)][string]$OutFile,
        [ValidateSet('preview', 'original')][string]$Type = 'original'
    )

    if ($Type -eq 'preview') {
        $url = "https://yandex.ru/archive/api/image?id=$SheetId&type=preview"
    }
    else {
        # grant отдаёт подписанный url и ставит куку — качать надо в той же сессии
        $grant = Invoke-RestMethod -Uri 'https://yandex.ru/archive/api/image-grant' -Method Post `
            -Body (@{ nodeId = $SheetId } | ConvertTo-Json) -ContentType 'application/json' `
            -Headers $script:YaHeaders -TimeoutSec 60 -SessionVariable sess
        $url = 'https://yandex.ru' + $grant.url
        Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing -WebSession $sess `
            -Headers @{ 'Referer' = "https://yandex.ru/archive/catalog/$SheetId" } -TimeoutSec 180
        return (Get-Item $OutFile)
    }

    Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing -Headers $script:YaHeaders -TimeoutSec 180
    Get-Item $OutFile
}

function Get-YaSheetId {
    <# id и размеры конкретной страницы документа — нужны для Get-YaImage и для кадрирования #>
    param(
        [Parameter(Mandatory)][string]$NodeId,
        [Parameter(Mandatory)][int]$Page
    )
    $cn = (Get-YaNextData -Url "https://yandex.ru/archive/catalog/$NodeId/$Page").props.pageProps.currentNode
    [pscustomobject]@{
        SheetId = $cn.id
        Width   = $cn.originalImageSize.width
        Height  = $cn.originalImageSize.height
        Source  = $cn.namepath
    }
}

function Get-YaPageText {
    <# Полный распознанный текст страницы. -Match фильтрует блоки по регулярке. #>
    param(
        [Parameter(Mandatory)][string]$NodeId,
        [Parameter(Mandatory)][int]$Page,
        [string]$Match
    )

    $pp = (Get-YaNextData -Url "https://yandex.ru/archive/catalog/$NodeId/$Page").props.pageProps
    $blocks = $pp.currentNode.textBlocks
    if ($Match) { $blocks = $blocks | Where-Object { $_.text -match $Match } }

    [pscustomobject]@{
        Source = $pp.currentNode.namepath
        Url    = "https://yandex.ru/archive/catalog/$NodeId/$Page"
        Text   = (($blocks | ForEach-Object { $_.text.Trim() }) -join "`n")
    }
}
