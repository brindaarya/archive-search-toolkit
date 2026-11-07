# goskatalog.ps1 — доступ к Госкаталогу Музейного фонда РФ (goskatalog.ru) без браузера.
#
# Портал — это AngularJS-обёртка над REST API, который открыт и не требует авторизации:
#   POST /muzfo-rest/rest/exhibits/ext  — поиск (фильтры в query-строке, критерии в теле)
#   GET  /muzfo-rest/rest/exhibits/{id} — полная карточка предмета
#   GET  /muzfo-imaginator/rest/images/public/{size}/{imgId}/{imgId}.jpg — изображение
#   POST /ai-search/by_image            — поиск похожих предметов по картинке
#
# Две особенности, на которые легко напороться:
#   1. Тело запроса — JSON-МАССИВ критериев. Пустое тело или [] — можно, {} — 400.
#   2. Подсчёт общего числа (calcCountsType=1) и фильтры без текстового запроса
#      кладут сервер в таймаут. Поэтому -Total выключен по умолчанию.
#
# Использование:
#   . .\goskatalog.ps1
#   $r = Search-Gk -Query 'усадьба Быково' -WithImage -Max 200
#   $r | Export-GkGallery -Path .\results\bykovo.html -Open
#   $r | Save-GkImage -Path .\results\images

$script:GkBase = 'https://goskatalog.ru'
$script:GkHeaders = @{
    'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
    'Accept-Language' = 'ru-RU,ru;q=0.9'
    'Referer'         = 'https://goskatalog.ru/portal/'
}
$script:GkCacheDir = Join-Path $PSScriptRoot 'cache'
$script:GkMuseums = $null
$script:GkDicts = $null

# statusId 6 = «в реестре», то есть опубликованные предметы. Портал всегда шлёт именно его.
$script:GkStatusPublished = 6

#region -------- инфраструктура --------

function Invoke-GkPost {
    param(
        [string]$Path,
        [hashtable]$Query = @{},
        [array]$Criteria = @(),
        [int]$TimeoutSec = 120
    )

    $pairs = foreach ($k in $Query.Keys) {
        $v = $Query[$k]
        if ($null -ne $v -and "$v" -ne '') { "$k=$([uri]::EscapeDataString([string]$v))" }
    }
    $url = $script:GkBase + $Path + '?' + ($pairs -join '&')

    # ConvertTo-Json в PS 5.1 разворачивает массив из одного элемента в объект,
    # поэтому массив собираем строкой вручную.
    $json = '[' + (($Criteria | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join ',') + ']'
    $body = [Text.Encoding]::UTF8.GetBytes($json)

    $resp = Invoke-WebRequest -Uri $url -Method Post -Body $body -ContentType 'application/json' `
        -UseBasicParsing -Headers $script:GkHeaders -TimeoutSec $TimeoutSec
    [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
}

function Invoke-GkGet {
    param([string]$Path, [int]$TimeoutSec = 120)
    $resp = Invoke-WebRequest -Uri ($script:GkBase + $Path) -UseBasicParsing `
        -Headers $script:GkHeaders -TimeoutSec $TimeoutSec
    [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
}

function New-GkCriterion {
    param(
        [string]$FieldName,
        [string]$FieldType = 'String',
        [string]$Operator = 'CONTAINS',
        $Value = $null,
        $FromValue = $null,
        $ToValue = $null
    )
    [ordered]@{
        fieldName = $FieldName
        fieldType = $FieldType
        operator  = $Operator
        fromValue = $FromValue
        toValue   = $ToValue
        value     = $Value
    }
}

function Get-GkCachedJson {
    <# Справочники живут в cache\ и обновляются раз в 30 дней. #>
    param([string]$Name, [string]$Path)

    if (-not (Test-Path $script:GkCacheDir)) { New-Item -ItemType Directory -Path $script:GkCacheDir | Out-Null }
    $file = Join-Path $script:GkCacheDir "$Name.json"

    $stale = $true
    if (Test-Path $file) {
        $stale = ((Get-Date) - (Get-Item $file).LastWriteTime).TotalDays -gt 30
    }
    if ($stale) {
        Write-Verbose "Обновляю справочник $Name"
        $resp = Invoke-WebRequest -Uri ($script:GkBase + $Path) -UseBasicParsing `
            -Headers $script:GkHeaders -TimeoutSec 180
        $txt = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        [IO.File]::WriteAllText($file, $txt, [Text.Encoding]::UTF8)
    }
    [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Get-GkMuseumMap {
    if ($null -eq $script:GkMuseums) {
        $data = Get-GkCachedJson -Name 'museums' -Path '/muzfo-rest/rest/museums?cacheEnabled=true'
        $map = @{}
        foreach ($m in $data.museums) { $map[[int]$m.id] = $m }
        $script:GkMuseums = $map
    }
    $script:GkMuseums
}

function Get-GkDicts {
    if ($null -eq $script:GkDicts) {
        $script:GkDicts = Get-GkCachedJson -Name 'dicts' -Path '/muzfo-rest/rest/dicts'
    }
    $script:GkDicts
}

#endregion

#region -------- справочники --------

function Get-GkTypology {
    <# Типология предмета: живопись, графика, «фотографии и негативы» и т.д. #>
    (Get-GkDicts).typology | Sort-Object id | ForEach-Object {
        [pscustomobject]@{ Id = $_.id; Name = $_.name }
    }
}

function Resolve-GkTypology {
    param([string]$Value)
    if (-not $Value) { return $null }
    if ($Value -match '^\d+$') { return [int]$Value }

    $all = Get-GkTypology
    $hit = @($all | Where-Object { $_.Name -like "*$Value*" })
    if ($hit.Count -eq 1) { return $hit[0].Id }
    if ($hit.Count -eq 0) {
        throw "Типология '$Value' не найдена. Доступно: " + (($all.Name) -join '; ')
    }
    throw "Типология '$Value' неоднозначна: " + (($hit.Name) -join '; ')
}

function Find-GkMuseum {
    <#
      Поиск музея по названию или городу — нужен, чтобы получить Id для Search-Gk -MuseumId.
        Find-GkMuseum -Name 'Щусева'
        Find-GkMuseum -Name 'краеведческий' -City 'Раменское'
    #>
    param(
        [string]$Name,
        [string]$City,
        [int]$Max = 50
    )

    $map = Get-GkMuseumMap
    $res = $map.Values
    if ($Name) { $res = $res | Where-Object { $_.name -like "*$Name*" -or $_.abbreviation -like "*$Name*" } }
    if ($City) { $res = $res | Where-Object { $_.addressString -like "*$City*" } }

    $res | Sort-Object name | Select-Object -First $Max | ForEach-Object {
        [pscustomobject]@{
            Id      = [int]$_.id
            Name    = $_.name
            Short   = $_.abbreviation
            Address = $_.addressString
            Url     = "$($script:GkBase)/portal/#/museums?id=$($_.id)"
        }
    }
}

#endregion

#region -------- поиск --------

function ConvertTo-GkItem {
    param($Obj, $MuseumMap)

    $imgIds = @()
    if ($Obj.images) { $imgIds = @($Obj.images | Where-Object { -not $_.deleted } | ForEach-Object { $_.id }) }
    $mainId = if ($Obj.mainImage) { $Obj.mainImage.id } elseif ($imgIds.Count) { $imgIds[0] } else { $null }

    $museum = $null
    if ($Obj.museumId -and $MuseumMap.ContainsKey([int]$Obj.museumId)) {
        $museum = $MuseumMap[[int]$Obj.museumId].name
    }

    [pscustomobject]@{
        Id           = $Obj.id
        Name         = $Obj.name
        Museum       = $museum
        MuseumId     = $Obj.museumId
        Typology     = ($script:GkTypologyMap[[int]$Obj.typologyId])
        Authors      = (($Obj.authors | ForEach-Object { $_.name }) -join '; ')
        Technologies = (($Obj.technologies | ForEach-Object { $_.name }) -join ', ')
        RegNumber    = $Obj.regNumber
        GikNumber    = $Obj.gikNumber
        ImageCount   = $imgIds.Count
        ImageId      = $mainId
        ImageIds     = $imgIds
        Thumb        = if ($mainId) { "$($script:GkBase)/muzfo-imaginator/rest/images/public/350/$mainId/$mainId.jpg" } else { $null }
        Image        = if ($mainId) { "$($script:GkBase)/muzfo-imaginator/rest/images/public/2000/$mainId/$mainId.jpg" } else { $null }
        Url          = "$($script:GkBase)/portal/#/collections?id=$($Obj.id)"
    }
}

function Search-Gk {
    <#
      Поиск по Госкаталогу.

      -Query        полнотекстовый поиск (то же поле, что на сайте) — самый быстрый фильтр
      -Name         вхождение в название предмета
      -Author       вхождение в автора
      -Technology   материал/техника («фотобумага», «холст, масло»)
      -Typology     тип предмета: 'фотографии' , 'живопись', 'графика'... или число
      -MuseumId     один или несколько id музеев (см. Find-GkMuseum)
      -WithImage    только предметы с изображением
      -NoImage      только без изображения
      -Max          сколько предметов вернуть (страницами по 100)
      -Total        дополнительно посчитать общее число совпадений (медленно, десятки секунд)

      Примеры:
        Search-Gk -Query 'усадьба Быково' -WithImage -Max 300
        Search-Gk -Query 'Быково' -Typology 'фотографии' -WithImage
        Search-Gk -Author 'Шехтель' -WithImage -Max 100
        Search-Gk -GikNumber 'ГНИМА НФ-ОФ-1348/254'

      Осторожно: -MuseumId или -Typology БЕЗ -Query/-Name сервер обрабатывает очень
      долго (может уйти в таймаут) — по возможности всегда задавайте текст запроса.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Query,
        [string]$Name,
        [string]$Author,
        [string]$Producer,
        [string]$Technology,
        [string]$Typology,
        [int[]]$MuseumId,
        [string]$GikNumber,
        [string]$InvNumber,
        [long]$RegNumber,
        [switch]$WithImage,
        [switch]$NoImage,
        [int]$Max = 100,
        [switch]$Total,
        [int]$DelayMs = 300,
        [int]$TimeoutSec = 120
    )

    if ($WithImage -and $NoImage) { throw 'Нельзя одновременно -WithImage и -NoImage' }

    # карта типологий для расшифровки в результатах
    if (-not $script:GkTypologyMap) {
        $script:GkTypologyMap = @{}
        foreach ($t in (Get-GkTypology)) { $script:GkTypologyMap[[int]$t.Id] = $t.Name }
    }
    $museumMap = Get-GkMuseumMap

    $criteria = @()
    if ($Name) { $criteria += New-GkCriterion -FieldName 'name' -Value $Name }
    if ($Author) { $criteria += New-GkCriterion -FieldName 'authors' -Value $Author }
    if ($Producer) { $criteria += New-GkCriterion -FieldName 'producers' -Value $Producer }
    if ($Technology) { $criteria += New-GkCriterion -FieldName 'technologies' -Value $Technology }
    if ($GikNumber) { $criteria += New-GkCriterion -FieldName 'gikNumber' -Operator 'EQUALS' -Value $GikNumber }
    if ($InvNumber) { $criteria += New-GkCriterion -FieldName 'invNumber' -Operator 'EQUALS' -Value $InvNumber }
    if ($PSBoundParameters.ContainsKey('RegNumber')) {
        $criteria += New-GkCriterion -FieldName 'regNumber' -FieldType 'Number' -Operator 'EQUALS' -Value $RegNumber
    }

    $qp = @{
        statusIds        = $script:GkStatusPublished
        publicationLimit = 'false'
        calcCountsType   = 0
        sortFields       = 'id'
        dirFields        = 'desc'
    }
    if ($Query) { $qp['q'] = $Query }
    if ($MuseumId) { $qp['museumIds'] = ($MuseumId -join ',') }
    if ($Typology) { $qp['typologyId'] = (Resolve-GkTypology $Typology) }
    if ($WithImage) { $qp['imageExists'] = 'true' }
    if ($NoImage) { $qp['imageExists'] = 'false' }

    if (-not $Query -and -not $criteria.Count) {
        Write-Warning 'Запрос без текстовых условий — сервер может отвечать очень долго.'
    }

    if ($Total) {
        $cq = $qp.Clone()
        $cq['calcCountsType'] = 1; $cq['limit'] = 0; $cq['offset'] = 0
        $cq.Remove('sortFields'); $cq.Remove('dirFields')
        try {
            $cnt = Invoke-GkPost -Path '/muzfo-rest/rest/exhibits/ext' -Query $cq -Criteria $criteria -TimeoutSec $TimeoutSec
            Write-Host "Всего совпадений: $($cnt.statistics[0].count)" -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Подсчёт не удался (обычно это таймаут сервера): $($_.Exception.Message)"
        }
    }

    $offset = 0
    $got = 0
    while ($got -lt $Max) {
        $take = [Math]::Min(100, $Max - $got)
        $pq = $qp.Clone()
        $pq['limit'] = $take
        $pq['offset'] = $offset

        $resp = Invoke-GkPost -Path '/muzfo-rest/rest/exhibits/ext' -Query $pq -Criteria $criteria -TimeoutSec $TimeoutSec
        $objs = @($resp.objects)
        if (-not $objs.Count) { break }

        foreach ($o in $objs) { ConvertTo-GkItem -Obj $o -MuseumMap $museumMap }

        $got += $objs.Count
        $offset += $objs.Count
        if ($objs.Count -lt $take) { break }
        Start-Sleep -Milliseconds $DelayMs
    }
}

function Get-GkItem {
    <#
      Полная карточка предмета: описание, датировка, размеры, место создания.
      В поиске этих полей нет — их приходится добирать по одному.
        Search-Gk -Query 'Быково' -Max 20 | Get-GkItem
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [long]$Id,
        [int]$DelayMs = 200,
        [int]$TimeoutSec = 120
    )

    begin { $museumMap = Get-GkMuseumMap }

    process {
        $d = Invoke-GkGet -Path "/muzfo-rest/rest/exhibits/$Id" -TimeoutSec $TimeoutSec

        $imgIds = @()
        if ($d.images) { $imgIds = @($d.images | Where-Object { -not $_.deleted } | ForEach-Object { $_.id }) }
        $mainId = if ($imgIds.Count) { $imgIds[0] } else { $null }

        $museum = $null
        if ($d.museumId -and $museumMap.ContainsKey([int]$d.museumId)) { $museum = $museumMap[[int]$d.museumId].name }

        [pscustomobject]@{
            Id              = $Id
            Name            = $d.name
            Description     = $d.description
            Period          = $d.periodStr
            StartDate       = $d.startDate
            FinishDate      = $d.finishDate
            Dimensions      = $d.dimStr
            ProductionPlace = $d.productionPlace
            FindPlace       = $d.findPlace
            Museum          = $museum
            MuseumId        = $d.museumId
            Authors         = (($d.authors | ForEach-Object { $_.name }) -join '; ')
            Technologies    = (($d.technologies | ForEach-Object { $_.name }) -join ', ')
            RegNumber       = $d.regNumber
            GikNumber       = $d.gikNumber
            ImageCount      = $imgIds.Count
            ImageId         = $mainId
            ImageIds        = $imgIds
            Thumb           = if ($mainId) { "$($script:GkBase)/muzfo-imaginator/rest/images/public/350/$mainId/$mainId.jpg" } else { $null }
            Image           = if ($mainId) { "$($script:GkBase)/muzfo-imaginator/rest/images/public/2000/$mainId/$mainId.jpg" } else { $null }
            Url             = "$($script:GkBase)/portal/#/collections?id=$Id"
        }

        Start-Sleep -Milliseconds $DelayMs
    }
}

#endregion

#region -------- изображения --------

function Get-GkImageUrl {
    <#
      Ссылка на файл изображения. Публичные копии ограничены примерно 1024 px
      по длинной стороне; любой размер больше отдаёт максимум, что есть.
        -Size 350  — превью для галереи
        -Size 2000 — максимальное доступное качество
    #>
    param(
        [Parameter(Mandatory)][long]$ImageId,
        [int]$Size = 2000
    )
    "$($script:GkBase)/muzfo-imaginator/rest/images/public/$Size/$ImageId/$ImageId.jpg"
}

function ConvertTo-GkSlug {
    param([string]$Text, [int]$MaxLength = 60)
    if (-not $Text) { return 'item' }
    $s = $Text -replace '[\\/:*?"<>|]', ' ' -replace '\s+', ' '
    $s = $s.Trim()
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength).Trim() }
    if (-not $s) { 'item' } else { $s }
}

function Save-GkImage {
    <#
      Скачивает изображения найденных предметов.
        Search-Gk -Query 'усадьба Быково' -WithImage -Max 100 | Save-GkImage -Path .\results\images
      -All      — все изображения предмета, а не только главное
      -Size     — 350 (превью) или 2000 (максимум, по умолчанию)
      Уже скачанные файлы пропускаются, так что команду можно повторять.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [int]$Size = 2000,
        [switch]$All,
        [switch]$Force,
        [int]$DelayMs = 250,
        [int]$TimeoutSec = 180
    )

    begin {
        if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        $n = 0; $skipped = 0; $failed = 0
    }

    process {
        $ids = if ($All -and $InputObject.ImageIds) { @($InputObject.ImageIds) }
        elseif ($InputObject.ImageId) { @($InputObject.ImageId) }
        else { @() }
        if (-not $ids.Count) { return }

        $slug = ConvertTo-GkSlug $InputObject.Name
        $i = 0
        foreach ($imgId in $ids) {
            $i++
            $suffix = if ($ids.Count -gt 1) { "-$i" } else { '' }
            $file = Join-Path $Path ("{0}{1} {2}.jpg" -f $InputObject.Id, $suffix, $slug)

            if ((Test-Path $file) -and -not $Force) { $skipped++; continue }

            try {
                try {
                    Invoke-WebRequest -Uri (Get-GkImageUrl -ImageId $imgId -Size $Size) -OutFile $file `
                        -UseBasicParsing -Headers $script:GkHeaders -TimeoutSec $TimeoutSec
                }
                catch {
                    # У части предметов крупной копии просто нет — тогда 404, и остаётся превью.
                    if ($Size -eq 350) { throw }
                    Write-Verbose "$imgId : нет размера $Size, беру 350"
                    Invoke-WebRequest -Uri (Get-GkImageUrl -ImageId $imgId -Size 350) -OutFile $file `
                        -UseBasicParsing -Headers $script:GkHeaders -TimeoutSec $TimeoutSec
                }
                $n++
                Get-Item $file
            }
            catch {
                $failed++
                if (Test-Path $file) { Remove-Item $file -Force }   # не оставлять пустышку
                Write-Warning "Не скачалось $imgId ($($InputObject.Id)): $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds $DelayMs
        }
    }

    end { Write-Host "Скачано: $n, пропущено (уже есть): $skipped, ошибок: $failed" -ForegroundColor Cyan }
}

function Search-GkByImage {
    <#
      Поиск визуально похожих предметов по своей картинке.
      Это тот же ИИ-поиск, что кнопкой на сайте: он ищет похожее изображение,
      а не тот же самый предмет, поэтому точного совпадения может и не быть.
        Search-GkByImage -Path .\my-photo.jpg
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSec = 180
    )

    if (-not (Test-Path $Path)) { throw "Файл не найден: $Path" }

    $bytes = [IO.File]::ReadAllBytes((Resolve-Path $Path))
    $boundary = '----gk' + [Guid]::NewGuid().ToString('N')
    $latin = [Text.Encoding]::GetEncoding('iso-8859-1')
    $head = "--$boundary`r`nContent-Disposition: form-data; name=`"image`"; filename=`"query.jpg`"`r`nContent-Type: image/jpeg`r`n`r`n"
    $tail = "`r`n--$boundary--`r`n"

    # Именно поток: в PS 5.1 «byte[] + byte[]» даёт Object[], и запрос ломается.
    $ms = New-Object IO.MemoryStream
    $h = $latin.GetBytes($head); $t = $latin.GetBytes($tail)
    $ms.Write($h, 0, $h.Length); $ms.Write($bytes, 0, $bytes.Length); $ms.Write($t, 0, $t.Length)
    $body = $ms.ToArray(); $ms.Dispose()

    $resp = Invoke-WebRequest -Uri "$($script:GkBase)/ai-search/by_image?collection_types=PUBLIC" `
        -Method Post -Body $body -ContentType "multipart/form-data; boundary=$boundary" `
        -UseBasicParsing -Headers $script:GkHeaders -TimeoutSec $TimeoutSec
    $j = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json

    if ($j.predicted_classes) {
        $cls = ($j.predicted_classes | ForEach-Object { '{0} ({1:N0}%)' -f $_.category_name, ($_.category_probability * 100) }) -join ', '
        Write-Host "ИИ считает, что это: $cls" -ForegroundColor DarkGray
    }

    foreach ($it in $j.items) {
        [pscustomobject]@{
            Id         = $it.nearest_parent_id
            Name       = $it.item_name
            Similarity = [math]::Round($it.mean_similarity_score * 100, 1)
            Category   = $it.item_category
            ImageId    = $it.nearest_image_id
            ImageIds   = @($it.nearest_image_id)
            Thumb      = Get-GkImageUrl -ImageId $it.nearest_image_id -Size 350
            Image      = Get-GkImageUrl -ImageId $it.nearest_image_id -Size 2000
            Url        = "$($script:GkBase)/portal/#/collections?id=$($it.nearest_parent_id)"
        }
    }
}

#endregion

#region -------- вывод --------

function ConvertTo-GkHtml {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function Export-GkGallery {
    <#
      Контактный лист: все находки с превью на одной странице, каждая карточка —
      ссылка на предмет в Госкаталоге и на полное изображение.
        Search-Gk -Query 'усадьба Быково' -WithImage -Max 300 | Export-GkGallery -Path .\results\bykovo.html -Open
      Превью тянутся с сайта по ссылкам, так что файл маленький, но требует интернета.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [string]$Title = 'Госкаталог — результаты поиска',
        [switch]$Open
    )

    begin { $items = New-Object Collections.ArrayList }
    process { [void]$items.Add($InputObject) }

    end {
        $cards = foreach ($it in $items) {
            $thumb = if ($it.Thumb) {
                '<a href="{0}" target="_blank"><img loading="lazy" src="{1}" alt=""></a>' -f (ConvertTo-GkHtml $it.Image), (ConvertTo-GkHtml $it.Thumb)
            }
            else { '<div class="noimg">без изображения</div>' }

            $meta = @()
            if ($it.Similarity) { $meta += 'похоже на ' + $it.Similarity + '%' }
            if ($it.Period) { $meta += ConvertTo-GkHtml $it.Period }
            if ($it.Authors) { $meta += ConvertTo-GkHtml $it.Authors }
            if ($it.Technologies) { $meta += ConvertTo-GkHtml $it.Technologies }
            if ($it.Dimensions) { $meta += ConvertTo-GkHtml $it.Dimensions }

            @"
<figure>
  $thumb
  <figcaption>
    <a class="ttl" href="$(ConvertTo-GkHtml $it.Url)" target="_blank">$(ConvertTo-GkHtml $it.Name)</a>
    <div class="meta">$($meta -join ' · ')</div>
    <div class="mus">$(ConvertTo-GkHtml $it.Museum)</div>
    <div class="num">$(ConvertTo-GkHtml $it.GikNumber) &nbsp; № $(ConvertTo-GkHtml $it.RegNumber)</div>
  </figcaption>
</figure>
"@
        }

        $html = @"
<!doctype html>
<meta charset="utf-8">
<title>$(ConvertTo-GkHtml $Title)</title>
<style>
  body { font: 14px/1.45 -apple-system, "Segoe UI", Roboto, sans-serif; margin: 24px; background:#fafaf8; color:#1c1b19; }
  h1 { font-size: 20px; font-weight: 600; margin: 0 0 4px; }
  .sub { color:#6b6862; margin-bottom: 20px; }
  .grid { display:grid; grid-template-columns: repeat(auto-fill, minmax(230px,1fr)); gap:18px; }
  figure { margin:0; background:#fff; border:1px solid #e6e3dd; border-radius:6px; overflow:hidden; display:flex; flex-direction:column; }
  figure img { width:100%; height:200px; object-fit:cover; display:block; background:#f0eeea; }
  .noimg { height:200px; display:flex; align-items:center; justify-content:center; color:#a8a49c; background:#f0eeea; font-size:12px; }
  figcaption { padding:10px 12px 12px; }
  .ttl { display:block; color:#1c1b19; text-decoration:none; font-weight:600; margin-bottom:5px; }
  .ttl:hover { text-decoration:underline; }
  .meta { color:#57534d; font-size:12px; }
  .mus  { color:#6b6862; font-size:12px; margin-top:5px; }
  .num  { color:#a8a49c; font-size:11px; margin-top:3px; }
</style>
<h1>$(ConvertTo-GkHtml $Title)</h1>
<div class="sub">$($items.Count) предметов · выгружено $(Get-Date -Format 'dd.MM.yyyy HH:mm') · goskatalog.ru</div>
<div class="grid">
$($cards -join "`n")
</div>
"@

        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($Path, $html, [Text.Encoding]::UTF8)
        Write-Host "Галерея: $Path ($($items.Count) предметов)" -ForegroundColor Cyan
        if ($Open) { Invoke-Item $Path }
    }
}

#endregion
