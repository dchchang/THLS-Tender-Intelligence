param(
    [string]$BaseDir = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($BaseDir)) {
    $BaseDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$settingsPath = Join-Path $BaseDir "settings.txt"
$outputDir = Join-Path $BaseDir "output"

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $outputDir ("log_" + $stamp + ".txt")
$pagesPath = Join-Path $outputDir ("pages_" + $stamp + ".csv")

function Write-Log {
    param([string]$Message)

    $line = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $Message
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Read-Settings {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Settings file not found: $Path"
    }

    $result = @{}

    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $text = $line.Trim()

        if ($text.Length -eq 0 -or $text.StartsWith("#")) {
            continue
        }

        $pos = $text.IndexOf("=")

        if ($pos -le 0) {
            continue
        }

        $key = $text.Substring(0, $pos).Trim()
        $value = $text.Substring($pos + 1).Trim()
        $result[$key] = $value
    }

    return $result
}

function Normalize-Url {
    param(
        [string]$Href,
        [Uri]$BaseUri
    )

    if ([string]::IsNullOrWhiteSpace($Href)) {
        return $null
    }

    $hrefText = $Href.Trim()

    if (
        $hrefText.StartsWith("#") -or
        $hrefText.StartsWith("javascript:", [System.StringComparison]::OrdinalIgnoreCase) -or
        $hrefText.StartsWith("mailto:", [System.StringComparison]::OrdinalIgnoreCase) -or
        $hrefText.StartsWith("tel:", [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        return $null
    }

    try {
        return ([Uri]::new($BaseUri, $hrefText)).AbsoluteUri
    }
    catch {
        return $null
    }
}

Write-Log "THLS crawler step 1 started"
Write-Log ("Base directory: " + $BaseDir)

$settings = Read-Settings -Path $settingsPath

$startUrl = $settings["START_URL"]
$allowedDomain = $settings["ALLOWED_DOMAIN"]

if ([string]::IsNullOrWhiteSpace($startUrl)) {
    throw "START_URL is missing."
}

if ([string]::IsNullOrWhiteSpace($allowedDomain)) {
    throw "ALLOWED_DOMAIN is missing."
}

Write-Log ("Start URL: " + $startUrl)
Write-Log ("Allowed domain: " + $allowedDomain)

$headers = @{
    "User-Agent" = "Mozilla/5.0 THLS-Tender-Intelligence-Crawler/9.0"
}

$response = Invoke-WebRequest `
    -Uri $startUrl `
    -Headers $headers `
    -UseBasicParsing `
    -TimeoutSec 30

Write-Log ("HTTP status: " + [int]$response.StatusCode)
Write-Log ("Downloaded bytes: " + $response.RawContentLength)

$baseUri = [Uri]$startUrl
$foundUrls = New-Object System.Collections.Generic.HashSet[string]

$hrefPattern = 'href\s*=\s*["'']([^"'']+)["'']'
$matches = [regex]::Matches(
    $response.Content,
    $hrefPattern,
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

foreach ($match in $matches) {
    $absoluteUrl = Normalize-Url -Href $match.Groups[1].Value -BaseUri $baseUri

    if ([string]::IsNullOrWhiteSpace($absoluteUrl)) {
        continue
    }

    try {
        $uri = [Uri]$absoluteUrl

        if ($uri.Host -ieq $allowedDomain) {
            [void]$foundUrls.Add($uri.AbsoluteUri)
        }
    }
    catch {
    }
}

$rows = foreach ($url in ($foundUrls | Sort-Object)) {
    [PSCustomObject]@{
        Url = $url
        IsPdf = $url.ToLowerInvariant().EndsWith(".pdf")
    }
}

$rows | Export-Csv `
    -LiteralPath $pagesPath `
    -NoTypeInformation `
    -Encoding UTF8

$latestPagesPath = Join-Path $outputDir "latest_pages.csv"
Copy-Item -LiteralPath $pagesPath -Destination $latestPagesPath -Force

Write-Log ("Same-domain links found: " + $rows.Count)
Write-Log ("Output CSV: " + $pagesPath)
Write-Log "Step 1 completed successfully"
