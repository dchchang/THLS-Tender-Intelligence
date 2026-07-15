# THLS Tender Intelligence

THLS product website crawler and tender matching platform.

## Phase 1 — THLS website crawler

The crawler:

- starts from `https://www.thls.com.tw/`
- stays within the configured THLS domain
- discovers internal pages and PDF links
- records successful pages and failures
- identifies probable product pages
- creates CSV, JSON, HTML, and log outputs

## Run on Windows

1. Open the `crawler` folder.
2. Edit `settings.txt` if needed.
3. Double-click `run_crawler.bat`.
4. Review files in `crawler/output`.

## Outputs

- `latest_report.html`
- `latest_pages.csv`
- `latest_product_candidates.csv`
- `latest_pdf_links.csv`
- `latest_failures.csv`
- `latest_products.json`
- `latest_log.txt`

## Important

This crawler records only pages that were actually fetched. It does not claim the whole site was scanned unless the crawl queue completes.
