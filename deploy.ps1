# Quick Deployment Script for Azure Functions
# This script uses the clean publish folder method to ensure functions.metadata is included

param(
    [Parameter(Mandatory=$false)]
    [string]$FunctionAppName = "func-lumovy7q3a",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    
    [switch]$SkipHealthCheck = $false
)

$ErrorActionPreference = "Stop"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  AZURE FUNCTIONS DEPLOYMENT" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Step 1: Health check (optional)
if (-not $SkipHealthCheck) {
    Write-Host "[1/6] Running health check..." -ForegroundColor Yellow
    if (Test-Path ".\azure-health-check.ps1") {
        .\azure-health-check.ps1 -AutoFix
        Write-Host ""
    } else {
        Write-Host "  [SKIP] Health check script not found, skipping..." -ForegroundColor Gray
    }
} else {
    Write-Host "[1/6] Skipping health check (--SkipHealthCheck)" -ForegroundColor Gray
}

# Step 2: Clean previous build
Write-Host "`n[2/6] Cleaning previous build..." -ForegroundColor Yellow
dotnet clean --configuration $Configuration --verbosity quiet
if (Test-Path ".\publish") {
    Remove-Item -Path ".\publish" -Recurse -Force
    Write-Host "  [OK] Removed old publish folder" -ForegroundColor Green
}

# Step 3: Build
Write-Host "`n[3/6] Building project..." -ForegroundColor Yellow
dotnet build FunctionApp1.csproj --configuration $Configuration --verbosity quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [FAIL] Build failed!" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] Build succeeded" -ForegroundColor Green

# Step 4: Publish to clean folder
Write-Host "`n[4/6] Publishing to ./publish folder..." -ForegroundColor Yellow
dotnet publish FunctionApp1.csproj --configuration $Configuration --output ./publish --verbosity quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [FAIL] Publish failed!" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] Publish succeeded" -ForegroundColor Green

# Step 5: Verify functions.metadata exists
Write-Host "`n[5/6] Verifying functions.metadata..." -ForegroundColor Yellow
if (-not (Test-Path ".\publish\functions.metadata")) {
    Write-Host "  [FAIL] functions.metadata not found in publish folder!" -ForegroundColor Red
    Write-Host "    This will cause '0 functions found' error after deployment." -ForegroundColor Red
    exit 1
}
$metadataSize = (Get-Item ".\publish\functions.metadata").Length
Write-Host "  [OK] functions.metadata found ($metadataSize bytes)" -ForegroundColor Green

# Parse metadata to show function count
$metadata = Get-Content ".\publish\functions.metadata" | ConvertFrom-Json
$functionCount = $metadata.Count
Write-Host "  [OK] $functionCount function(s) defined:" -ForegroundColor Green
foreach ($func in $metadata) {
    $triggerType = $func.bindings[0].type
    Write-Host "    - $($func.name) [$triggerType]" -ForegroundColor White
}

# Step 6: Deploy
Write-Host "`n[6/6] Deploying to $FunctionAppName..." -ForegroundColor Yellow
Push-Location publish
try {
    func azure functionapp publish $FunctionAppName --no-build --dotnet-isolated
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [FAIL] Deployment failed!" -ForegroundColor Red
        Pop-Location
        exit 1
    }
} finally {
    Pop-Location
}

# Verification
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Verifying function discovery..." -ForegroundColor Yellow
Start-Sleep -Seconds 3  # Give Azure a moment to sync

$discoveredFunctions = func azure functionapp list-functions $FunctionAppName 2>&1
Write-Host ""
Write-Host $discoveredFunctions

if ($discoveredFunctions -match "ArchiveFunction" -and 
    $discoveredFunctions -match "BlobIngestFunction" -and 
    $discoveredFunctions -match "RowProcessorFunction") {
    Write-Host "`n[OK] SUCCESS: All 3 functions discovered!" -ForegroundColor Green
    Write-Host "`nNext steps:" -ForegroundColor Cyan
    Write-Host "  1. Upload a CSV to the 'incoming' container to test the pipeline" -ForegroundColor White
    Write-Host "  2. Monitor logs: Portal -> $FunctionAppName -> Monitoring -> Log stream" -ForegroundColor White
    Write-Host "  3. Check SQL: Query the Contacts and FileIngestions tables" -ForegroundColor White
} else {
    Write-Host "`n[WARN] WARNING: Functions may not have been discovered correctly." -ForegroundColor Yellow
    Write-Host "Check the Log Stream in Azure Portal for errors." -ForegroundColor Yellow
    Write-Host "See the Troubleshooting section in Spec/azure-deployment.md for diagnostics." -ForegroundColor Yellow
}

Write-Host ""
