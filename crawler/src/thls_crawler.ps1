param(
    [string]$BaseDir = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ([string]::IsNullOrWhiteSpace($BaseDir)) {
    $BaseDir = Split-Path -Parent $PSScriptRoot
}

$settingsPath = Join-Path $BaseDir "settings.txt"
$outputDir = Join-Path $BaseDir "output"
$cacheDir = Join-Path $BaseDir "cache"

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $outputDir ("log_" + $stamp + ".txt")
$latestLogPath = Join-Path $outputDir "latest_log.txt"

function Write-Log {
    param([string]$Message)
    $line = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $Message
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Add-Content -LiteralPath $latestLogPath -Value $line -Encoding UTF8
}

function Read-KeyValueFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Settings file not found: $Path"
    }
    $result = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $text = $line.Trim()
        if ($text.Length -eq 0 -or $text.StartsWith("#")) { continue }
        $pos = $text.IndexOf("=")
        if ($pos -le 0) { continue }
        $key = $text.Substring(0, $pos).Trim()
        $value = $text.Substring($pos + 1).Trim()
        $result[$key] = $value
    }
    return $result
}

function Html-Decode {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return [System.Net.WebUtility]::HtmlDecode($Text)
}

function Strip-Html {
    param([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return "" }
    $text = [regex]::Replace($Html, "(?is)<script.*?</script>", " ")
    $text = [regex]::Replace($text, "(?is)<style.*?</style>", " ")
    $text = [regex]::Replace($text, "(?is)<[^>]+>", " ")
    $text = Html-Decode $text
    return ([regex]::Replace($text, "\s+", " ")).Trim()
}

function Get-Title {
    param([string]$Html)
    $m = [regex]::Match($Html, "(?is)<title[^>]*>(.*?)</title>")
    if ($m.Success) { return Strip-Html $m.Groups[1].Value }
    return ""
}

function Normalize-Url {
    param([string]$Href, [Uri]$BaseUri)
    if ([string]::IsNullOrWhiteSpace($Href)) { return $null }
    $h = (Html-Decode $Href).Trim()
    if ($h.StartsWith("#")) { return $null }
    if ($h -match "^(?i)(javascript:|mailto:|tel:|data:)") { return $null }
    try {
        $u = [Uri]::new($BaseUri, $h)
        $builder = New-Object System.UriBuilder($u)
        $builder.Fragment = ""
        return $builder.Uri.AbsoluteUri
    } catch {
        return $null
    }
}

function Safe-FileName {
    param([string]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").Substring(0, 24)
    } finally {
        $sha.Dispose()
    }
}

function Csv-Escape {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"', '""') + '"'
}

function Write-CsvFile {
    param([string]$Path, [string[]]$Headers, [object[]]$Rows)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(($Headers | ForEach-Object { Csv-Escape $_ }) -join ",")
    foreach ($row in $Rows) {
        $values = foreach ($h in $Headers) { Csv-Escape ([string]$row.$h) }
        $lines.Add($values -join ",")
    }
    [IO.File]::WriteAllLines($Path, $lines, (New-Object Text.UTF8Encoding($true)))
}

Remove-Item -LiteralPath $latestLogPath -Force -ErrorAction SilentlyContinue
Write-Log "THLS crawler Phase 1 started"
Write-Log ("BaseDir: " + $BaseDir)

$settings = Read-KeyValueFile $settingsPath
$startUrl = $settings["START_URL"]
$allowedDomains = @($settings["ALLOWED_DOMAINS"].Split(",") | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$maxPages = [int]$settings["MAX_PAGES"]
$delayMs = [int]$settings["DELAY_MS"]
$timeoutSec = [int]$settings["TIMEOUT_SEC"]
$saveHtml = $settings["SAVE_HTML"] -ieq "true"

if ([string]::IsNullOrWhiteSpace($startUrl)) { throw "START_URL is missing." }
if ($allowedDomains.Count -eq 0) { throw "ALLOWED_DOMAINS is missing." }
if ($maxPages -lt 1) { throw "MAX_PAGES must be at least 1." }

Write-Log ("Start URL: " + $startUrl)
Write-Log ("Allowed domains: " + ($allowedDomains -join ", "))
Write-Log ("Max pages: " + $maxPages)

$headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) THLS-Tender-Intelligence/9.0"
    "Accept-Language" = "zh-TW,zh;q=0.9,en;q=0.7"
}

$queue = New-Object System.Collections.Generic.Queue[string]
$queued = New-Object System.Collections.Generic.HashSet[string]
$visited = New-Object System.Collections.Generic.HashSet[string]
$pages = New-Object System.Collections.Generic.List[object]
$products = New-Object System.Collections.Generic.List[object]
$pdfs = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[object]

$queue.Enqueue($startUrl)
[void]$queued.Add($startUrl)

$productTerms = @(
    "product","products","category","brand","solution",
    "產品","商品","儀器","設備","試劑","耗材","品牌","應用"
)

while ($queue.Count -gt 0 -and $visited.Count -lt $maxPages) {
    $url = $queue.Dequeue()
    if ($visited.Contains($url)) { continue }
    [void]$visited.Add($url)

    Write-Log ("Fetch " + $visited.Count + "/" + $maxPages + ": " + $url)

    try {
        $response = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec $timeoutSec
        $html = [string]$response.Content
        $title = Get-Title $html
        $contentType = [string]$response.Headers["Content-Type"]

        $page = [PSCustomObject]@{
            Url = $url
            Status = [int]$response.StatusCode
            Title = $title
            ContentType = $contentType
            Bytes = [Text.Encoding]::UTF8.GetByteCount($html)
            FetchedAt = (Get-Date).ToString("s")
        }
        $pages.Add($page)

        if ($saveHtml) {
            $fileName = (Safe-FileName $url) + ".html"
            [IO.File]::WriteAllText((Join-Path $cacheDir $fileName), $html, (New-Object Text.UTF8Encoding($false)))
        }

        $isProductCandidate = $false
        $lowerProbe = ($url + " " + $title).ToLowerInvariant()
        foreach ($term in $productTerms) {
            if ($lowerProbe.Contains($term.ToLowerInvariant())) {
                $isProductCandidate = $true
                break
            }
        }
        if ($isProductCandidate) {
            $products.Add([PSCustomObject]@{
                Title = $title
                Url = $url
                Source = "page-title-or-url"
            })
        }

        $baseUri = [Uri]$url
        $matches = [regex]::Matches($html, "(?is)href\s*=\s*(['`"])(.*?)\1")
        foreach ($m in $matches) {
            $absolute = Normalize-Url $m.Groups[2].Value $baseUri
            if ([string]::IsNullOrWhiteSpace($absolute)) { continue }

            try {
                $uri = [Uri]$absolute
            } catch {
                continue
            }

            $host = $uri.Host.ToLowerInvariant()
            $allowed = $false
            foreach ($domain in $allowedDomains) {
                if ($host -eq $domain -or $host.EndsWith("." + $domain)) {
                    $allowed = $true
                    break
                }
            }
            if (-not $allowed) { continue }

            if ($uri.AbsolutePath.ToLowerInvariant().EndsWith(".pdf")) {
                $pdfs.Add([PSCustomObject]@{
                    PdfUrl = $absolute
                    FoundOn = $url
                })
                continue
            }

            if (-not $visited.Contains($absolute) -and -not $queued.Contains($absolute)) {
                $queue.Enqueue($absolute)
                [void]$queued.Add($absolute)
            }
        }

        if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
    }
    catch {
        $message = $_.Exception.Message
        Write-Log ("FAILED: " + $message)
        $failures.Add([PSCustomObject]@{
            Url = $url
            Error = $message
            FailedAt = (Get-Date).ToString("s")
        })
    }
}

$pagesUnique = @($pages | Sort-Object Url -Unique)
$productsUnique = @($products | Sort-Object Url -Unique)
$pdfsUnique = @($pdfs | Sort-Object PdfUrl -Unique)
$failuresUnique = @($failures | Sort-Object Url -Unique)

$pagesCsv = Join-Path $outputDir ("pages_" + $stamp + ".csv")
$productsCsv = Join-Path $outputDir ("product_candidates_" + $stamp + ".csv")
$pdfCsv = Join-Path $outputDir ("pdf_links_" + $stamp + ".csv")
$failuresCsv = Join-Path $outputDir ("failures_" + $stamp + ".csv")
$jsonPath = Join-Path $outputDir ("products_" + $stamp + ".json")
$reportPath = Join-Path $outputDir ("report_" + $stamp + ".html")

Write-CsvFile $pagesCsv @("Url","Status","Title","ContentType","Bytes","FetchedAt") $pagesUnique
Write-CsvFile $productsCsv @("Title","Url","Source") $productsUnique
Write-CsvFile $pdfCsv @("PdfUrl","FoundOn") $pdfsUnique
Write-CsvFile $failuresCsv @("Url","Error","FailedAt") $failuresUnique

$jsonObject = [ordered]@{
    generatedAt = (Get-Date).ToString("s")
    startUrl = $startUrl
    pagesFetched = $pagesUnique.Count
    productCandidates = $productsUnique.Count
    pdfLinks = $pdfsUnique.Count
    failures = $failuresUnique.Count
    products = $productsUnique
}
$jsonObject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$rowsHtml = ($productsUnique | Select-Object -First 200 | ForEach-Object {
    "<tr><td>" + [Net.WebUtility]::HtmlEncode($_.Title) + "</td><td><a target='_blank' href='" +
    [Net.WebUtility]::HtmlEncode($_.Url) + "'>Open</a></td></tr>"
}) -join [Environment]::NewLine

$html = @"
<!doctype html>
<html><head><meta charset="utf-8"><title>THLS Crawler Report</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#f5f7fb;margin:24px;color:#1f2937}
.card{background:white;padding:20px;border-radius:14px;margin-bottom:16px;box-shadow:0 4px 16px rgba(0,0,0,.08)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}
.box{background:#eef2ff;padding:16px;border-radius:10px}.num{font-size:28px;font-weight:700}
table{width:100%;border-collapse:collapse}th{background:#1e3a8a;color:white;text-align:left;padding:9px}
td{padding:9px;border-bottom:1px solid #e5e7eb}a{color:#0f766e;font-weight:600}
</style></head><body>
<div class="card"><h1>THLS Website Crawler — Phase 1</h1>
<div>Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</div>
<div>Start URL: $([Net.WebUtility]::HtmlEncode($startUrl))</div></div>
<div class="card grid">
<div class="box"><div>Pages fetched</div><div class="num">$($pagesUnique.Count)</div></div>
<div class="box"><div>Product candidates</div><div class="num">$($productsUnique.Count)</div></div>
<div class="box"><div>PDF links</div><div class="num">$($pdfsUnique.Count)</div></div>
<div class="box"><div>Failures</div><div class="num">$($failuresUnique.Count)</div></div>
</div>
<div class="card"><h2>Product candidates</h2>
<table><thead><tr><th>Title</th><th>Link</th></tr></thead><tbody>$rowsHtml</tbody></table></div>
</body></html>
"@
[IO.File]::WriteAllText($reportPath, $html, (New-Object Text.UTF8Encoding($false)))

Copy-Item $pagesCsv (Join-Path $outputDir "latest_pages.csv") -Force
Copy-Item $productsCsv (Join-Path $outputDir "latest_product_candidates.csv") -Force
Copy-Item $pdfCsv (Join-Path $outputDir "latest_pdf_links.csv") -Force
Copy-Item $failuresCsv (Join-Path $outputDir "latest_failures.csv") -Force
Copy-Item $jsonPath (Join-Path $outputDir "latest_products.json") -Force
Copy-Item $reportPath (Join-Path $outputDir "latest_report.html") -Force
Copy-Item $logPath $latestLogPath -Force

Write-Log ("Pages fetched: " + $pagesUnique.Count)
Write-Log ("Product candidates: " + $productsUnique.Count)
Write-Log ("PDF links: " + $pdfsUnique.Count)
Write-Log ("Failures: " + $failuresUnique.Count)
Write-Log "Phase 1 completed successfully"
