# Create Required Storage Containers
# Run this if 'incoming' or 'archive' containers are missing

$ErrorActionPreference = "Stop"
$storageAccount = "stlumovy7q3a"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "CREATING STORAGE CONTAINERS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "[1/2] Creating 'incoming' container..." -ForegroundColor Yellow
try {
    $result = az storage container create --name incoming --account-name $storageAccount --auth-mode login 2>&1 | ConvertFrom-Json
    if ($result.created -eq $true) {
        Write-Host "  Created successfully." -ForegroundColor Green
    } else {
        Write-Host "  Already exists." -ForegroundColor Gray
    }
} catch {
    Write-Host "  Already exists or error: $_" -ForegroundColor Gray
}

Write-Host "`n[2/2] Creating 'archive' container..." -ForegroundColor Yellow
try {
    $result = az storage container create --name archive --account-name $storageAccount --auth-mode login 2>&1 | ConvertFrom-Json
    if ($result.created -eq $true) {
        Write-Host "  Created successfully." -ForegroundColor Green
    } else {
        Write-Host "  Already exists." -ForegroundColor Gray
    }
} catch {
    Write-Host "  Already exists or error: $_" -ForegroundColor Gray
}

Write-Host "`n[Verification] Listing all containers..." -ForegroundColor Yellow
az storage container list --account-name $storageAccount --auth-mode login --query "[].{Name:name}" -o table

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "COMPLETE" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
