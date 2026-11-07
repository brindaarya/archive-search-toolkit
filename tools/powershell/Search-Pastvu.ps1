<#
.SYNOPSIS
    Поиск исторических фотографий на PastVu (pastvu.com) по описанию, координатам, месту или региону.

.DESCRIPTION
    Работает через открытый API https://pastvu.com/api2 (методы photo.giveNearestPhotos,
    photo.getByBounds, photo.givePS, photo.giveForPage, region.giveListPublic).

    ВАЖНО про «поиск по описанию»: полнотекстового поиска в API PastVu нет.
    Скрипт сначала выбирает снимки по географии (радиус / прямоугольник / регион),
    а затем фильтрует их по ключевым словам локально. Поэтому текстовый поиск всегда
    ограничен заданной областью и параметром -MaxScan.

.PARAMETER Text
    Ключевые слова. По умолчанию ищутся в названии снимка; с -Deep — ещё в описании,
    адресе, авторе и источнике (это стоит одного запроса на снимок).

.PARAMETER Place
    Название места («усадьба Быково», «Раменское, Московская область»).
    Координаты определяет геокодер OpenStreetMap Nominatim.

.PARAMETER Lat
    Широта центра поиска (вместе с -Lon).

.PARAMETER Lon
    Долгота центра поиска (вместе с -Lat).

.PARAMETER Radius
    Радиус поиска в метрах, по умолчанию 2000, максимум 1000000.

.PARAMETER Bbox
    Прямоугольник «lat1,lon1,lat2,lon2» (любые два противоположных угла).

.PARAMETER Region
    Название региона PastVu — от страны до городского округа, например «Раменский городской округ».
    Список: .\Search-Pastvu.ps1 -ListRegions -Region Раменск

.PARAMETER Deep
    Догружать карточку каждого снимка и искать слова также в описании и адресе.
    Медленно: один HTTP-запрос на снимок.

.PARAMETER Comments
    Догружать обсуждение под снимком: на PastVu в комментариях часто уточняют
    датировку, адрес и что именно изображено. Поле CommentCount заполняется всегда.

.EXAMPLE
    .\Search-Pastvu.ps1 -Place 'усадьба Быково' -Radius 800
    Все снимки в радиусе 800 м от усадьбы.

.EXAMPLE
    .\Search-Pastvu.ps1 -Text 'церковь' -Place 'Быково, Раменский район' -Radius 3000 -YearTo 1950
    Снимки до 1950 года со словом «церковь» в названии.

.EXAMPLE
    .\Search-Pastvu.ps1 -Text 'усадьб' -Region 'Раменский городской округ' -MaxScan 2000 -CsvPath .\usadby.csv
    Сканирует до 2000 снимков округа и выгружает совпадения в CSV.

.EXAMPLE
    .\Search-Pastvu.ps1 -Lat 55.6099 -Lon 38.0583 -Radius 500 -Deep -Text 'Баженов'
    Ищет упоминание Баженова в названиях и описаниях снимков вокруг точки.

.NOTES
    PowerShell 5.1+, внешних зависимостей нет.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Text,

    [string]$Place,
    [double]$Lat,
    [double]$Lon,
    [ValidateRange(1, 1000000)]
    [int]$Radius = 2000,
    [string]$Bbox,
    [string]$Region,

    [int]$YearFrom,
    [int]$YearTo,
    [ValidateSet('any', 'photo', 'painting')]
    [string]$Type = 'any',

    [ValidateSet('all', 'any')]
    [string]$Match = 'all',
    [switch]$Regex,
    [switch]$Deep,

    [int]$Limit = 50,
    [int]$MaxScan = 1000,

    [switch]$Comments,

    [ValidateSet('a', 'd', 'h', 'm', 'q', 's', 'x')]
    [string]$ImageSize = 'd',

    [string]$CsvPath,
    [string]$JsonPath,
    [string]$DownloadTo,
    [switch]$ListRegions
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:ApiRoot = 'https://pastvu.com/api2'
$script:SiteRoot = 'https://pastvu.com'
$script:UserAgent = 'Search-Pastvu.ps1/1.0 (personal archive research)'

# ---------------------------------------------------------------- HTTP / API

function Get-Utf8Response {
    param([string]$Uri, [int]$Retries = 3)

    # Локально гасим прогресс-бар Invoke-WebRequest, он сильно замедляет загрузку
    $ProgressPreference = 'SilentlyContinue'

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60 `
                -UserAgent $script:UserAgent -Headers @{ 'Accept' = 'application/json' }

            # Ответ приходит без charset, поэтому декодируем UTF-8 сами — иначе кириллица бьётся
            return [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        } catch [Net.WebException] {
            if ($attempt -eq $Retries) { throw }
            Write-Verbose "Сеть подвела ($($_.Exception.Message)), попытка $($attempt + 1) из $Retries"
            Start-Sleep -Seconds ($attempt * 3)
        }
    }
}

function Invoke-PastvuApi {
    param(
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{}
    )

    $json = $Params | ConvertTo-Json -Compress -Depth 10
    $uri = '{0}?method={1}&params={2}' -f $script:ApiRoot, $Method, [uri]::EscapeDataString($json)

    $body = Get-Utf8Response -Uri $uri
    $obj = $body | ConvertFrom-Json
    if ($null -ne $obj.result) { return $obj.result }

    $msg = $obj.message
    if (-not $msg) { $msg = $body }
    throw "PastVu API ($Method): $msg"
}

function Resolve-Place {
    param([Parameter(Mandatory)][string]$Query)

    $uri = 'https://nominatim.openstreetmap.org/search?format=jsonv2&limit=5&accept-language=ru&q=' +
        [uri]::EscapeDataString($Query)
    # ConvertFrom-Json в PS 5.1 отдаёт массив верхнего уровня одним объектом — разворачиваем вручную
    $parsed = Get-Utf8Response -Uri $uri | ConvertFrom-Json
    $hits = @()
    foreach ($h in $parsed) { $hits += $h }

    if ($hits.Count -eq 0) {
        throw "Место `"$Query`" геокодер не нашёл. Задайте -Lat/-Lon вручную."
    }

    $best = $hits[0]
    Write-Host ("Место: " + $best.display_name) -ForegroundColor Cyan
    Write-Host ("Координаты: " + $best.lat + ", " + $best.lon) -ForegroundColor Cyan
    if ($hits.Count -gt 1) {
        Write-Host 'Другие варианты геокодера:' -ForegroundColor DarkGray
        foreach ($h in $hits[1..($hits.Count - 1)]) {
            Write-Host ("  " + $h.display_name + " (" + $h.lat + ", " + $h.lon + ")") -ForegroundColor DarkGray
        }
    }

    [pscustomobject]@{ Lat = [double]$best.lat; Lon = [double]$best.lon; Name = $best.display_name }
}

function Get-Distance {
    # Гаверсинус, метры
    param([double]$Lat1, [double]$Lon1, [double]$Lat2, [double]$Lon2)

    $r = 6371000.0
    $p1 = $Lat1 * [Math]::PI / 180
    $p2 = $Lat2 * [Math]::PI / 180
    $dp = ($Lat2 - $Lat1) * [Math]::PI / 180
    $dl = ($Lon2 - $Lon1) * [Math]::PI / 180

    $a = [Math]::Sin($dp / 2) * [Math]::Sin($dp / 2) +
         [Math]::Cos($p1) * [Math]::Cos($p2) * [Math]::Sin($dl / 2) * [Math]::Sin($dl / 2)
    [int][Math]::Round($r * 2 * [Math]::Atan2([Math]::Sqrt($a), [Math]::Sqrt(1 - $a)), 0)
}

# ---------------------------------------------------------------- источники снимков

function Get-PhotosByRadius {
    param([double]$CenterLat, [double]$CenterLon, [int]$RadiusMeters, [int]$Max)

    $collected = @()
    $skip = 0
    $pageSize = 30   # предел API

    while ($collected.Count -lt $Max) {
        $params = @{ geo = @($CenterLat, $CenterLon); distance = $RadiusMeters; limit = $pageSize; skip = $skip }
        if ($script:ApiYear) { $params.year = $script:ApiYear }
        if ($script:ApiYear2) { $params.year2 = $script:ApiYear2 }
        if ($script:ApiType) { $params.type = $script:ApiType }

        # Where-Object отсекает $null: иначе пустая страница выглядела бы как непустая
        $page = @((Invoke-PastvuApi -Method 'photo.giveNearestPhotos' -Params $params).photos | Where-Object { $_ })
        if ($page.Count -eq 0) { break }

        $collected += $page
        Write-Progress -Activity 'PastVu: загрузка снимков' -Status "получено $($collected.Count)"
        if ($page.Count -lt $pageSize) { break }

        $skip += $pageSize
        Start-Sleep -Milliseconds 200
    }

    Write-Progress -Activity 'PastVu: загрузка снимков' -Completed
    $collected
}

function Get-PhotosByBbox {
    param([double]$Lat1, [double]$Lon1, [double]$Lat2, [double]$Lon2)

    $south = [Math]::Min($Lat1, $Lat2); $north = [Math]::Max($Lat1, $Lat2)
    $west = [Math]::Min($Lon1, $Lon2); $east = [Math]::Max($Lon1, $Lon2)

    # Кольцо против часовой стрелки, координаты в порядке [lon, lat]
    $ring = @(
        , @($west, $south)
        , @($east, $south)
        , @($east, $north)
        , @($west, $north)
        , @($west, $south)
    )
    $params = @{
        z         = 17          # с 17-го зума API отдаёт снимки, а не кластеры
        localWork = 1
        geometry  = @{ type = 'Polygon'; coordinates = @(, $ring) }
    }
    if ($script:ApiYear) { $params.year = $script:ApiYear }
    if ($script:ApiYear2) { $params.year2 = $script:ApiYear2 }
    if ($script:ApiType -eq 'painting') { $params.isPainting = 1 }

    @((Invoke-PastvuApi -Method 'photo.getByBounds' -Params $params).photos | Where-Object { $_ })
}

function Get-RegionList {
    if ($script:RegionCache) { return $script:RegionCache }

    # Справочник регионов весит несколько мегабайт, поэтому держим его месяц на диске
    $cacheFile = Join-Path $env:TEMP 'pastvu-regions.json'
    if (Test-Path $cacheFile) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalDays -lt 30) {
            try {
                $cached = [IO.File]::ReadAllText($cacheFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
                $script:RegionCache = @($cached.result.regions)
                if ($script:RegionCache.Count -gt 0) { return $script:RegionCache }
            } catch {
                Write-Verbose 'Кэш регионов не читается, перезапрашиваю с сайта'
            }
        }
    }

    Write-Host 'Загружаю справочник регионов PastVu (один раз в месяц)...' -ForegroundColor DarkGray
    $body = Get-Utf8Response -Uri ($script:ApiRoot + '?method=region.giveListPublic&params=%7B%7D')
    $script:RegionCache = @(($body | ConvertFrom-Json).result.regions)
    try {
        [IO.File]::WriteAllText($cacheFile, $body, [Text.UTF8Encoding]::new($false))
    } catch {
        Write-Verbose "Кэш регионов не сохранён: $($_.Exception.Message)"
    }
    $script:RegionCache
}

function Resolve-Region {
    param([Parameter(Mandatory)][string]$Name)

    $all = Get-RegionList
    $exact = @($all | Where-Object { $_.title_local -eq $Name -or $_.title_en -eq $Name })
    if ($exact.Count -gt 0) { return $exact[0] }

    # Из частичных совпадений берём регион с наибольшим числом снимков
    $like = @($all |
        Where-Object { $_.title_local -like "*$Name*" -or $_.title_en -like "*$Name*" } |
        Sort-Object -Property phc -Descending)
    if ($like.Count -eq 0) {
        throw "Регион `"$Name`" не найден. Список: .\Search-Pastvu.ps1 -ListRegions -Region <часть названия>"
    }
    if ($like.Count -gt 1) {
        $others = ($like | Select-Object -First 5 | ForEach-Object { '{0} ({1})' -f $_.title_local, $_.phc }) -join '; '
        Write-Warning "Подходит несколько регионов, взят первый: $others"
    }
    $like[0]
}

function Get-PhotosByRegion {
    param([int]$RegionCid, [int]$Max)

    $filterParts = @("r!$RegionCid")
    if ($script:ApiYear -or $script:ApiYear2) {
        $y1 = 1826; $y2 = (Get-Date).Year
        if ($script:ApiYear) { $y1 = $script:ApiYear }
        if ($script:ApiYear2) { $y2 = $script:ApiYear2 }
        $filterParts += "y!$y1!$y2"
    }
    if ($script:ApiType -eq 'photo') { $filterParts += 't!1' }
    elseif ($script:ApiType -eq 'painting') { $filterParts += 't!2' }
    $filter = $filterParts -join '_'

    $collected = @()
    $skip = 0
    $pageSize = 100
    $total = $null

    while ($collected.Count -lt $Max) {
        $take = [Math]::Min($pageSize, $Max - $collected.Count)
        $result = Invoke-PastvuApi -Method 'photo.givePS' -Params @{ filter = $filter; limit = $take; skip = $skip }

        if ($null -eq $total) {
            $total = $result.count
            Write-Host ("Снимков под фильтр: {0}; будет просмотрено не более {1}" -f $total, $Max) -ForegroundColor Cyan
        }

        $page = @($result.photos | Where-Object { $_ })
        if ($page.Count -eq 0) { break }

        # Цепочку регионов разворачиваем в читаемый путь
        foreach ($p in $page) {
            if ($p.rs -and $result.rhash) {
                $names = foreach ($rc in $p.rs) {
                    $node = $result.rhash.PSObject.Properties[[string]$rc]
                    if ($node) { $node.Value.title_local }
                }
                $p | Add-Member -NotePropertyName 'regionPath' -NotePropertyValue (($names | Where-Object { $_ }) -join ' / ') -Force
            }
        }

        $collected += $page
        Write-Progress -Activity 'PastVu: сканирование' -Status "просмотрено $($collected.Count) из $Max" `
            -PercentComplete ([Math]::Min(100, 100 * $collected.Count / $Max))
        if ($page.Count -lt $take) { break }

        $skip += $take
        Start-Sleep -Milliseconds 200
    }

    Write-Progress -Activity 'PastVu: сканирование' -Completed
    $collected
}

function Get-CommentsFlat {
    # Комментарии приходят деревом — разворачиваем в плоский список по времени
    param([int]$Cid)

    try {
        $r = Invoke-PastvuApi -Method 'comment.giveForObj' -Params @{ cid = $Cid }
    } catch {
        Write-Verbose "Комментарии к $Cid не получены: $($_.Exception.Message)"
        return @()
    }

    $flat = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    # Внимание: @($null) в PowerShell — это массив из одного $null, поэтому
    # ветки дерева кладём в стек только после явной проверки, иначе цикл не кончится
    foreach ($c in @($r.comments)) { if ($c) { $stack.Push($c) } }

    $guard = 5000
    while ($stack.Count -gt 0 -and $flat.Count -lt $guard) {
        $c = $stack.Pop()
        if (-not $c) { continue }

        $name = $c.user
        if ($r.users -and $c.user) {
            $u = $r.users.PSObject.Properties[[string]$c.user]
            if ($u -and $u.Value.disp) { $name = $u.Value.disp }
        }
        [void]$flat.Add([pscustomobject]@{
            Stamp = $c.stamp
            User  = $name
            Text  = Get-PlainText $c.txt
        })

        if ($c.comments) {
            foreach ($child in @($c.comments)) { if ($child) { $stack.Push($child) } }
        }
    }
    if ($flat.Count -ge $guard) { Write-Warning "Снимок $Cid : обсуждение обрезано на $guard комментариях" }

    @($flat | Sort-Object Stamp)
}

function Get-PhotoDetails {
    param([int]$Cid)

    try {
        (Invoke-PastvuApi -Method 'photo.giveForPage' -Params @{ cid = $Cid }).photo
    } catch {
        Write-Verbose "Карточка $Cid не получена: $($_.Exception.Message)"
        $null
    }
}

# ---------------------------------------------------------------- фильтрация и вывод

function Test-TextMatch {
    param([string[]]$Patterns, [string]$Haystack)

    if (-not $Patterns -or $Patterns.Count -eq 0) { return $true }
    if (-not $Haystack) { return $false }

    $hits = 0
    foreach ($p in $Patterns) {
        $needle = $p
        if (-not $Regex) { $needle = [regex]::Escape($p) }
        if ($Haystack -imatch $needle) { $hits++ }
    }

    if ($Match -eq 'all') { return ($hits -eq $Patterns.Count) }
    ($hits -gt 0)
}

function Get-PlainText {
    # В описании, авторе и источнике PastVu хранит HTML
    param([string]$Html)

    if (-not $Html) { return $Html }
    $t = $Html -replace '<br\s*/?>', ' ' -replace '<[^>]+>', ''
    $t = $t -replace '&nbsp;', ' ' -replace '&quot;', '"' -replace '&#39;', "'" -replace '&lt;', '<' -replace '&gt;', '>' -replace '&amp;', '&'
    ($t -replace '\s+', ' ').Trim()
}

function ConvertTo-Result {
    param($Photo, $Details, [double]$OriginLat, [double]$OriginLon, [bool]$HasOrigin)

    $geo = $Photo.geo
    $lat = $null; $lon = $null; $distance = $null
    if ($geo -and @($geo).Count -eq 2) {
        $lat = $geo[0]; $lon = $geo[1]
        if ($HasOrigin) { $distance = Get-Distance -Lat1 $OriginLat -Lon1 $OriginLon -Lat2 $lat -Lon2 $lon }
    }

    $years = [string]$Photo.year
    if ($Photo.year2 -and $Photo.year2 -ne $Photo.year) { $years = '{0}-{1}' -f $Photo.year, $Photo.year2 }

    $fields = [ordered]@{
        Cid      = $Photo.cid
        Year     = $years
        Title    = $Photo.title
        Distance = $distance
        Lat      = $lat
        Lon      = $lon
        Region   = $Photo.regionPath
        CommentCount = [int]$Photo.ccount
        Url      = '{0}/p/{1}' -f $script:SiteRoot, $Photo.cid
        Image    = '{0}/_p/{1}/{2}' -f $script:SiteRoot, $ImageSize, $Photo.file
    }
    if ($Details) {
        $fields.Description = Get-PlainText $Details.desc
        $fields.Address = Get-PlainText $Details.address
        $fields.Author = Get-PlainText $Details.author
        $fields.Source = Get-PlainText $Details.source
    }
    [pscustomobject]$fields
}

function Confirm-ParentDirectory {
    # Чтобы многоминутный сбор не пропал на последнем шаге из-за отсутствующей папки
    param([string]$Path)

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Get-SafeFileName {
    param([string]$Name)

    $pattern = '[{0}]' -f [regex]::Escape(([IO.Path]::GetInvalidFileNameChars() -join ''))
    $clean = ($Name -replace $pattern, '_').Trim()
    if ($clean.Length -gt 80) { $clean = $clean.Substring(0, 80) }
    if (-not $clean) { $clean = 'photo' }
    $clean
}

# ---------------------------------------------------------------- основной сценарий

if ($ListRegions) {
    $list = Get-RegionList
    if ($Region) { $list = @($list | Where-Object { $_.title_local -like "*$Region*" -or $_.title_en -like "*$Region*" }) }
    $list |
        Sort-Object -Property phc -Descending |
        Select-Object @{ n = 'Cid'; e = { $_.cid } },
                      @{ n = 'Регион'; e = { $_.title_local } },
                      @{ n = 'English'; e = { $_.title_en } },
                      @{ n = 'Снимков'; e = { $_.phc } }
    return
}

# Годы и тип отдаём самому API там, где он их поддерживает
$script:ApiYear = $null
$script:ApiYear2 = $null
$script:ApiType = $null
if ($PSBoundParameters.ContainsKey('YearFrom')) { $script:ApiYear = $YearFrom }
if ($PSBoundParameters.ContainsKey('YearTo')) { $script:ApiYear2 = $YearTo }
if ($Type -ne 'any') { $script:ApiType = $Type }

$hasCoords = $PSBoundParameters.ContainsKey('Lat') -and $PSBoundParameters.ContainsKey('Lon')
$originLat = 0.0; $originLon = 0.0; $hasOrigin = $false
$photos = @()
$mode = ''

if ($Bbox) {
    $nums = @($Bbox -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { [double]$_ })
    if ($nums.Count -ne 4) { throw 'Bbox задаётся как "lat1,lon1,lat2,lon2".' }
    $mode = 'прямоугольник'
    $originLat = ($nums[0] + $nums[2]) / 2; $originLon = ($nums[1] + $nums[3]) / 2; $hasOrigin = $true
    $photos = Get-PhotosByBbox -Lat1 $nums[0] -Lon1 $nums[1] -Lat2 $nums[2] -Lon2 $nums[3]
} elseif ($hasCoords -or $Place) {
    if ($hasCoords) {
        $originLat = $Lat; $originLon = $Lon
    } else {
        $geocoded = Resolve-Place -Query $Place
        $originLat = $geocoded.Lat; $originLon = $geocoded.Lon
    }
    $hasOrigin = $true
    $mode = "радиус $Radius м вокруг $originLat, $originLon"
    $photos = Get-PhotosByRadius -CenterLat $originLat -CenterLon $originLon -RadiusMeters $Radius -Max $MaxScan
} elseif ($Region) {
    $reg = Resolve-Region -Name $Region
    Write-Host ("Регион: {0} (cid {1}, снимков в базе {2})" -f $reg.title_local, $reg.cid, $reg.phc) -ForegroundColor Cyan
    $mode = "регион «$($reg.title_local)»"
    $photos = Get-PhotosByRegion -RegionCid $reg.cid -Max $MaxScan
} elseif ($Text) {
    Write-Warning 'Область не задана — просмотрю только последние загрузки всей базы. Точнее будет с -Place, -Lat/-Lon, -Bbox или -Region.'
    $mode = 'вся база, последние загрузки'
    $photos = Get-PhotosByRegion -RegionCid 0 -Max $MaxScan
} else {
    throw 'Нечего искать: задайте -Text и/или область (-Place, -Lat/-Lon, -Bbox, -Region).'
}

$photos = @($photos)
Write-Host ("Просмотрено снимков: {0} ({1})" -f $photos.Count, $mode) -ForegroundColor DarkGray

# Годы дофильтровываем на своей стороне: getByBounds их учитывает не всегда строго
$candidates = @(foreach ($p in $photos) {
    $y = $p.year
    if ($script:ApiYear -and $y -and $y -lt $script:ApiYear) { continue }
    if ($script:ApiYear2 -and $y -and $y -gt $script:ApiYear2) { continue }
    $p
})

# Карточки нужны заранее только если по ним идёт текстовый поиск
$deepSearch = $Deep -and $Text
if ($deepSearch) {
    Write-Host ("Режим -Deep: читаю {0} карточек, это примерно {1} с" -f `
        $candidates.Count, [Math]::Ceiling($candidates.Count * 0.4)) -ForegroundColor DarkGray
}

$results = @()
$i = 0
foreach ($p in $candidates) {
    $i++
    $details = $null
    $haystack = $p.title

    if ($deepSearch) {
        Write-Progress -Activity 'PastVu: чтение карточек' -Status "$i из $($candidates.Count)" `
            -PercentComplete ([Math]::Min(100, 100 * $i / [Math]::Max(1, $candidates.Count)))
        $details = Get-PhotoDetails -Cid $p.cid
        if ($details) {
            $haystack = @($details.title, $details.desc, $details.address, $details.author, $details.source) -join ' | '
        }
        Start-Sleep -Milliseconds 150
    }

    if (-not (Test-TextMatch -Patterns $Text -Haystack $haystack)) { continue }

    $results += ConvertTo-Result -Photo $p -Details $details -OriginLat $originLat -OriginLon $originLon -HasOrigin $hasOrigin

    # Без географии порядок выдачи и так финальный — можно остановиться раньше
    if (-not $hasOrigin -and -not $deepSearch -and $results.Count -ge $Limit) { break }
}
Write-Progress -Activity 'PastVu: чтение карточек' -Completed

if ($hasOrigin) {
    $results = @($results | Sort-Object -Property @{ Expression = { if ($null -eq $_.Distance) { [int]::MaxValue } else { $_.Distance } } })
} else {
    $results = @($results | Sort-Object -Property Year)
}
$results = @($results | Select-Object -First $Limit)

# -Deep без -Text: карточки догружаем уже только для итоговой выдачи
if ($Deep -and -not $Text -and $results.Count -gt 0) {
    Write-Host ("Читаю карточки для {0} снимков" -f $results.Count) -ForegroundColor DarkGray
    foreach ($r in $results) {
        $d = Get-PhotoDetails -Cid $r.Cid
        if ($d) {
            $r | Add-Member -NotePropertyName 'Description' -NotePropertyValue (Get-PlainText $d.desc) -Force
            $r | Add-Member -NotePropertyName 'Address' -NotePropertyValue (Get-PlainText $d.address) -Force
            $r | Add-Member -NotePropertyName 'Author' -NotePropertyValue (Get-PlainText $d.author) -Force
            $r | Add-Member -NotePropertyName 'Source' -NotePropertyValue (Get-PlainText $d.source) -Force
        }
        Start-Sleep -Milliseconds 150
    }
}

if ($Comments -and $results.Count -gt 0) {
    $withComments = @($results | Where-Object { $_.CommentCount -gt 0 })
    Write-Host ("Читаю комментарии к {0} снимкам" -f $withComments.Count) -ForegroundColor DarkGray
    foreach ($r in $withComments) {
        $threads = Get-CommentsFlat -Cid $r.Cid
        $text = ($threads | ForEach-Object { '{0}: {1}' -f $_.User, $_.Text }) -join ' ¶ '
        $r | Add-Member -NotePropertyName 'Comments' -NotePropertyValue $text -Force
        Start-Sleep -Milliseconds 150
    }
}

Write-Host ("Найдено: {0}" -f $results.Count) -ForegroundColor Green

if ($CsvPath) {
    Confirm-ParentDirectory -Path $CsvPath
    # Координаты в CSV пишем с точкой, иначе на русской локали получается «55,6080»
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $forCsv = foreach ($r in $results) {
        $copy = $r.PSObject.Copy()
        if ($null -ne $copy.Lat) { $copy.Lat = ([double]$copy.Lat).ToString($inv) }
        if ($null -ne $copy.Lon) { $copy.Lon = ([double]$copy.Lon).ToString($inv) }
        $copy
    }
    $forCsv | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV: $CsvPath" -ForegroundColor Green
}
if ($JsonPath) {
    Confirm-ParentDirectory -Path $JsonPath
    $results | ConvertTo-Json -Depth 6 | Out-File -FilePath $JsonPath -Encoding utf8
    Write-Host "JSON: $JsonPath" -ForegroundColor Green
}
if ($DownloadTo) {
    $ProgressPreference = 'SilentlyContinue'
    if (-not (Test-Path $DownloadTo)) { New-Item -ItemType Directory -Path $DownloadTo -Force | Out-Null }
    foreach ($r in $results) {
        $name = '{0}_{1}_{2}.jpg' -f $r.Cid, $r.Year, (Get-SafeFileName -Name $r.Title)
        $dest = Join-Path $DownloadTo $name
        try {
            Invoke-WebRequest -Uri $r.Image -OutFile $dest -UseBasicParsing -TimeoutSec 120 -UserAgent $script:UserAgent
            Start-Sleep -Milliseconds 200
        } catch {
            Write-Warning "Не скачалось $($r.Cid): $($_.Exception.Message)"
        }
    }
    Write-Host "Изображения: $DownloadTo" -ForegroundColor Green
}

$results
