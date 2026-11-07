# Search-ShplText.ps1 — тонкий универсальный поиск по ГПИБ (elib.shpl.ru),
# без предметной логики Search-Shpl.ps1 (та заточена под Быково).
#
#   . .\Search-ShplText.ps1
#   Search-ShplText -Query '+іоговъ' -MaxPages 2 | Format-Table Year, Title, Page
#
# Синтаксис люценовский: "фраза", +слово (AND), пробел = OR, слов*, "два слова"~15.
# Выдача двух видов строк: пронумерованная — издание, безномерная «Страница N» —
# попадание в распознанном тексте последнего изданияя.

$script:ShplRoot = 'http://elib.shpl.ru'

function Get-ShplHtml {
    param([Parameter(Mandatory)][string]$Uri)
    $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 90 `
        -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0 Safari/537.36' }
    [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
}

function ConvertFrom-ShplHtml {
    param([string]$Html)
    $t = $Html -replace '(?s)<[^>]+>', ' '
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    ($t -replace '\s+', ' ').Trim()
}

function Search-ShplText {
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$MaxPages = 3,
        [int]$PerPage = 100,
        [int]$MaxHitsPerNode = 6,
        [switch]$MetadataOnly,
        [int]$DelayMs = 500
    )

    $encoded = [uri]::EscapeDataString($Query)
    $texts = if ($MetadataOnly) { 'off' } else { 'on' }

    for ($page = 1; $page -le $MaxPages; $page++) {
        $uri = '{0}/ru/nodes/search?query={1}&search_in_metadata=on&search_in_texts={2}&per_page={3}&page={4}' -f `
            $script:ShplRoot, $encoded, $texts, $PerPage, $page

        $html = Get-ShplHtml -Uri $uri
        $rows = [regex]::Matches($html, '(?s)<tr[^>]*>.*?</tr>')
        if ($rows.Count -le 1) { break }

        $current = $null; $nodeHits = 0; $found = 0

        foreach ($row in $rows) {
            $rowHtml = $row.Value
            if ($rowHtml -notmatch '<td') { continue }
            $link = [regex]::Match($rowHtml, 'href="(/ru/nodes/\d+[^"]*)"')
            if (-not $link.Success) { continue }

            $cells = @()
            foreach ($m in [regex]::Matches($rowHtml, '(?s)<td[^>]*>(.*?)</td>')) {
                $cells += ConvertFrom-ShplHtml $m.Groups[1].Value
            }

            if ($rowHtml -match "<td class='first'>\s*\d+\s*</td>") {
                $found++; $nodeHits = 0
                $current = [pscustomobject]@{
                    Title = $cells[1]; Kind = $cells[2]; Author = $cells[3]
                    Year = $cells[10]; Parent = $cells[11]
                    Url = $script:ShplRoot + ($link.Groups[1].Value -replace '\?.*$', '')
                }
                [pscustomobject]@{
                    Query = $Query; Year = $current.Year; Author = $current.Author
                    Title = $current.Title; Kind = $current.Kind; Parent = $current.Parent
                    Page = ''; Snippet = (($cells[1..6] | Where-Object { $_ }) -join ' | ')
                    Url = $current.Url
                }
                continue
            }

            if ($current -and $nodeHits -lt $MaxHitsPerNode -and $cells[1] -match 'Страниц\w*\s*(\d+)') {
                $nodeHits++
                [pscustomobject]@{
                    Query = $Query; Year = $current.Year; Author = $current.Author
                    Title = $current.Title; Kind = $current.Kind; Parent = $current.Parent
                    Page = $Matches[1]; Snippet = $cells[2]
                    Url = $script:ShplRoot + $link.Groups[1].Value
                }
            }
        }

        if ($found -lt $PerPage) { break }
        Start-Sleep -Milliseconds $DelayMs
    }
}

function Get-ShplPageText {
    <# Распознанный текст страницы по её id (из ссылки вида /ru/nodes/<node>/view#page/<N>) #>
    param([Parameter(Mandatory)][int]$PageId)
    $j = Invoke-RestMethod -Uri "$script:ShplRoot/ru/pages/$PageId/read" -TimeoutSec 60
    $j.text
}
