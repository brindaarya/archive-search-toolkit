# Get-PdfText.ps1 — извлечение текстового слоя из PDF без сторонних утилит.
# Нужен там, где нет poppler/pdftotext (см. [[windows-shell-environment]]).
# Разбирает FlateDecode-потоки и достаёт операнды текстовых операторов Tj/TJ/'/".
#
#   . .\Get-PdfText.ps1
#   Get-PdfText -Path .\file.pdf -Match 'йог|Патанджали'
#
# Ограничение: строки в PDF могут быть закодированы через CID-шрифт, тогда
# без разбора ToUnicode получится мусор. Для OCR-слоёв русских сканов обычно
# используется WinAnsi/встроенная кодировка и текст читается как есть.

function Expand-FlateBytes {
    param([byte[]]$Data)
    try {
        # пропустить 2-байтовый zlib-заголовок
        $ms = New-Object System.IO.MemoryStream(, $Data[2..($Data.Length - 1)])
        $ds = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
        $out = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 8192
        while (($n = $ds.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n) }
        $ds.Close()
        return $out.ToArray()
    }
    catch { return $null }
}

function Get-PdfText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Match,
        [int]$MaxStreams = 0,
        [switch]$Raw
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $latin = [System.Text.Encoding]::GetEncoding(28591)   # latin-1: байт == символ
    $s = $latin.GetString($bytes)

    $rx = [regex]'stream\r?\n?'
    $results = @()
    $idx = 0; $count = 0

    while ($true) {
        $m = $rx.Match($s, $idx)
        if (-not $m.Success) { break }
        $start = $m.Index + $m.Length
        $end = $s.IndexOf('endstream', $start)
        if ($end -lt 0) { break }
        $idx = $end + 9
        $count++
        if ($MaxStreams -gt 0 -and $count -gt $MaxStreams) { break }

        $len = $end - $start
        if ($len -le 0) { continue }
        $chunk = $latin.GetBytes($s.Substring($start, $len))

        $plain = Expand-FlateBytes -Data $chunk
        if ($null -eq $plain) { continue }
        $text = $latin.GetString($plain)
        if ($text -notmatch '(Tj|TJ)') { continue }

        # операнды текстовых операторов
        $sb = New-Object System.Text.StringBuilder
        foreach ($tm in [regex]::Matches($text, '\((?:\\.|[^\\()])*\)')) {
            $v = $tm.Value.Substring(1, $tm.Value.Length - 2)
            $v = $v -replace '\\([()\\])', '$1' -replace '\\n', ' ' -replace '\\r', ' '
            [void]$sb.Append($v)
        }
        $piece = $sb.ToString()
        if (-not $piece.Trim()) { continue }

        # OCR русских сканов чаще всего в cp1251, пришедшем как latin-1
        $decoded = [System.Text.Encoding]::GetEncoding(1251).GetString($latin.GetBytes($piece))
        $best = if (($decoded -replace '[^Ѐ-ӿ]', '').Length -gt ($piece -replace '[^Ѐ-ӿ]', '').Length) { $decoded } else { $piece }

        if ($Match -and $best -notmatch $Match) { continue }
        $results += [pscustomobject]@{ Stream = $count; Length = $best.Length; Text = ($best -replace '\s+', ' ') }
    }

    if ($Raw) { return $results }
    $results
}
