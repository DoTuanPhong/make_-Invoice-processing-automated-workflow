<#
.SYNOPSIS
    Test webhook cua scenario Invoice Processing Automation.

.DESCRIPTION
    Gui 3 sample invoice (hop le / vuot nguong / khong hop le) den webhook cua scenario.

.EXAMPLE
    .\06-test-webhook.ps1 -WebhookUrl "https://hook.us1.make.com/xxxxxxxx/xxxxxxxx"

.EXAMPLE
    .\06-test-webhook.ps1 -WebhookUrl "https://hook.us1.make.com/xxx/yyy" -OnlyCase 1

.EXAMPLE
    .\06-test-webhook.ps1 -WebhookUrl "https://hook.us1.make.com/xxx/yyy" -SamplesFile "C:\path\to\custom.json"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$WebhookUrl,
    [string]$SamplesFile = (Join-Path $PSScriptRoot '04-sample-invoices.json'),
    [int]$OnlyCase = 0
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SamplesFile)) {
    Write-Error "Khong tim thay file samples: $SamplesFile"
    exit 1
}

$samples = (Get-Content $SamplesFile -Raw | ConvertFrom-Json).samples
if ($OnlyCase -gt 0) {
    $samples = @($samples | Where-Object { $_.case -like "$($OnlyCase)_*" })
}

foreach ($sample in $samples) {
    $body = $sample.payload | ConvertTo-Json -Depth 10
    Write-Host ">> Gui case: $($sample.case)" -ForegroundColor Cyan
    try {
        $resp = Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 30
        Write-Host "   OK: $($resp | ConvertTo-Json -Depth 5 -Compress)" -ForegroundColor Green
    }
    catch {
        Write-Host "   FAIL: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Response) {
            $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            Write-Host "   Body: $($sr.ReadToEnd())" -ForegroundColor Red
        }
    }
    Write-Host "   Expected: $($sample.expected)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host "Kiem tra ket qua trong:" -ForegroundColor Cyan
Write-Host "  - Google Sheets: Invoice Ledger (sheets Invoices / Exceptions)" -ForegroundColor Cyan
Write-Host "  - Slack: #finance, #finance-exceptions, #finance-errors" -ForegroundColor Cyan
Write-Host "  - Google Drive: folder Invoices/" -ForegroundColor Cyan
Write-Host "  - Make: scenario -> Run history (xem tung bundle)" -ForegroundColor Cyan
