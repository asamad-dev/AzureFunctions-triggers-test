# Azure Deployment Health Check & Auto-Fix
# This script verifies all Azure resources and fixes common issues

param(
    [switch]$AutoFix = $false
)

$ErrorActionPreference = "Continue"
$resourceGroup = "rg-lumovy7q3a"
$storageAccount = "stlumovy7q3a"
$sqlServer = "sql-lumovy7q3a"
$database = "ContactsDb"
$serviceBusNamespace = "sb-lumovy7q3a"
$functionApp = "func-lumovy7q3a"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  AZURE DEPLOYMENT HEALTH CHECK" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$issues = @()

# 1. Resource Group
Write-Host "[1] Checking Resource Group..." -ForegroundColor Yellow
$rg = az group show --name $resourceGroup --query "{Name:name, Location:location, State:properties.provisioningState}" -o json 2>&1 | ConvertFrom-Json
if ($rg.State -eq "Succeeded") {
    Write-Host "  [OK] Resource Group: $($rg.Name) ($($rg.Location))" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Resource Group issue detected" -ForegroundColor Red
    $issues += "Resource Group not in Succeeded state"
}

# 2. Storage Account
Write-Host "`n[2] Checking Storage Account..." -ForegroundColor Yellow
$storage = az storage account show --name $storageAccount --resource-group $resourceGroup --query "{Name:name, Location:location, State:provisioningState}" -o json 2>&1 | ConvertFrom-Json
if ($storage.State -eq "Succeeded") {
    Write-Host "  [OK] Storage Account: $($storage.Name) ($($storage.Location))" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Storage Account issue detected" -ForegroundColor Red
    $issues += "Storage Account not provisioned"
}

# 3. Storage Containers
Write-Host "`n[3] Checking Storage Containers..." -ForegroundColor Yellow
$containers = az storage container list --account-name $storageAccount --auth-mode login --query "[].name" -o json 2>&1 | ConvertFrom-Json
$hasIncoming = $containers -contains "incoming"
$hasArchive = $containers -contains "archive"

if ($hasIncoming -and $hasArchive) {
    Write-Host "  [OK] Containers: incoming, archive" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Missing containers:" -ForegroundColor Red
    if (-not $hasIncoming) { Write-Host "    - incoming" -ForegroundColor Red; $issues += "Missing 'incoming' container" }
    if (-not $hasArchive) { Write-Host "    - archive" -ForegroundColor Red; $issues += "Missing 'archive' container" }
    
    if ($AutoFix) {
        Write-Host "`n  -> Auto-fixing: Creating missing containers..." -ForegroundColor Cyan
        if (-not $hasIncoming) {
            az storage container create --name incoming --account-name $storageAccount --auth-mode login --output none
            Write-Host "    [OK] Created 'incoming'" -ForegroundColor Green
        }
        if (-not $hasArchive) {
            az storage container create --name archive --account-name $storageAccount --auth-mode login --output none
            Write-Host "    [OK] Created 'archive'" -ForegroundColor Green
        }
    }
}

# 4. Get Storage Connection String
$storageConnectionString = az storage account show-connection-string --name $storageAccount --resource-group $resourceGroup --query connectionString -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($storageConnectionString)) {
    Write-Host "  [WARN] Could not fetch storage connection string (skipping key comparison)" -ForegroundColor Yellow
    $storageConnectionString = $null
}

# 5. SQL Server
Write-Host "`n[4] Checking SQL Server..." -ForegroundColor Yellow
$sql = az sql server show --name $sqlServer --resource-group $resourceGroup --query "{Name:name, State:state}" -o json 2>&1 | ConvertFrom-Json
if ($sql.State -eq "Ready") {
    Write-Host "  [OK] SQL Server: $($sql.Name)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] SQL Server not ready" -ForegroundColor Red
    $issues += "SQL Server not in Ready state"
}

# 6. SQL Database
Write-Host "`n[5] Checking SQL Database..." -ForegroundColor Yellow
$db = az sql db show --name $database --server $sqlServer --resource-group $resourceGroup --query "{Name:name, Status:status}" -o json 2>&1 | ConvertFrom-Json
Write-Host "  [OK] Database: $($db.Name) (Status: $($db.Status))" -ForegroundColor Green

# 7. Service Bus
Write-Host "`n[6] Checking Service Bus..." -ForegroundColor Yellow
$sb = az servicebus namespace show --name $serviceBusNamespace --resource-group $resourceGroup --query "{Name:name, Status:status}" -o json 2>&1 | ConvertFrom-Json
if ($sb.Status -eq "Active") {
    Write-Host "  [OK] Service Bus: $($sb.Name)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Service Bus not active" -ForegroundColor Red
    $issues += "Service Bus not Active"
}

# 8. Service Bus Queues
Write-Host "`n[7] Checking Service Bus Queues..." -ForegroundColor Yellow
$queues = az servicebus queue list --namespace-name $serviceBusNamespace --resource-group $resourceGroup --query "[].name" -o json 2>&1 | ConvertFrom-Json
$hasContactsQueue = $queues -contains "contacts-queue"
$hasFileCompleteQueue = $queues -contains "file-complete-queue"

if ($hasContactsQueue -and $hasFileCompleteQueue) {
    Write-Host "  [OK] Queues: contacts-queue, file-complete-queue" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Missing queues" -ForegroundColor Red
    if (-not $hasContactsQueue) { $issues += "Missing 'contacts-queue'" }
    if (-not $hasFileCompleteQueue) { $issues += "Missing 'file-complete-queue'" }
}

# 9. Get Service Bus Connection String
$serviceBusConnectionString = az servicebus namespace authorization-rule keys list --namespace-name $serviceBusNamespace --resource-group $resourceGroup --name RootManageSharedAccessKey --query primaryConnectionString -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serviceBusConnectionString)) {
    Write-Host "  [WARN] Could not fetch Service Bus connection string (skipping comparison)" -ForegroundColor Yellow
    $serviceBusConnectionString = $null
}

# 10. Function App
Write-Host "`n[8] Checking Function App..." -ForegroundColor Yellow
$func = az functionapp show --name $functionApp --resource-group $resourceGroup --query "{Name:name, State:state}" -o json 2>&1 | ConvertFrom-Json
if ($func.State -eq "Running") {
    Write-Host "  [OK] Function App: $($func.Name) (Running)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Function App not running (State: $($func.State))" -ForegroundColor Red
    $issues += "Function App not Running"
}

# 11. Function App Settings
Write-Host "`n[9] Checking Function App Connection Strings..." -ForegroundColor Yellow
$settingsJson = az functionapp config appsettings list --name $functionApp --resource-group $resourceGroup --query "[?name=='AzureWebJobsStorage' || name=='StorageConnection' || name=='ServiceBusConnection' || name=='SqlConnectionString']" -o json 2>$null
$settings = $null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($settingsJson)) {
    try { $settings = $settingsJson | ConvertFrom-Json } catch {}
}

if ($null -eq $settings) {
    Write-Host "  [WARN] Could not fetch Function App settings - skipping connection string comparison" -ForegroundColor Yellow
} else {
    $currentAzureWebJobsStorage = ($settings | Where-Object { $_.name -eq "AzureWebJobsStorage" }).value
    $currentStorageConnection = ($settings | Where-Object { $_.name -eq "StorageConnection" }).value
    $currentServiceBusConnection = ($settings | Where-Object { $_.name -eq "ServiceBusConnection" }).value
    $currentSqlConnectionString = ($settings | Where-Object { $_.name -eq "SqlConnectionString" }).value

    $expectedSqlConnectionString = "Server=tcp:$sqlServer.database.windows.net,1433;Initial Catalog=ContactsDb;Authentication=Active Directory Default;Encrypt=True;"

    $settingsOk = $true

    if ($null -ne $storageConnectionString -and $currentAzureWebJobsStorage -ne $storageConnectionString) {
        Write-Host "  [FAIL] AzureWebJobsStorage mismatch" -ForegroundColor Red
        $issues += "AzureWebJobsStorage mismatch"
        $settingsOk = $false
    }

    if ($null -ne $storageConnectionString -and $currentStorageConnection -ne $storageConnectionString) {
        Write-Host "  [FAIL] StorageConnection mismatch" -ForegroundColor Red
        $issues += "StorageConnection mismatch"
        $settingsOk = $false
    }

    if ($null -ne $serviceBusConnectionString -and $currentServiceBusConnection -ne $serviceBusConnectionString) {
        Write-Host "  [FAIL] ServiceBusConnection mismatch" -ForegroundColor Red
        $issues += "ServiceBusConnection mismatch"
        $settingsOk = $false
    }

    if ($currentSqlConnectionString -ne $expectedSqlConnectionString) {
        Write-Host "  [FAIL] SqlConnectionString mismatch" -ForegroundColor Red
        $issues += "SqlConnectionString mismatch"
        $settingsOk = $false
    }

    if ($settingsOk) {
        Write-Host "  [OK] All connection strings are correct" -ForegroundColor Green
    } elseif ($AutoFix) {
        Write-Host "`n  -> Auto-fixing: Updating connection strings..." -ForegroundColor Cyan
        if ($null -ne $storageConnectionString) {
            az functionapp config appsettings set --name $functionApp --resource-group $resourceGroup --settings "AzureWebJobsStorage=$storageConnectionString" --output none
            az functionapp config appsettings set --name $functionApp --resource-group $resourceGroup --settings "StorageConnection=$storageConnectionString" --output none
        }
        if ($null -ne $serviceBusConnectionString) {
            az functionapp config appsettings set --name $functionApp --resource-group $resourceGroup --settings "ServiceBusConnection=$serviceBusConnectionString" --output none
        }
        az functionapp config appsettings set --name $functionApp --resource-group $resourceGroup --settings "SqlConnectionString=$expectedSqlConnectionString" --output none
        Write-Host "    [OK] Connection strings updated (Function App restarting...)" -ForegroundColor Green
    }
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  HEALTH CHECK SUMMARY" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if ($issues.Count -eq 0) {
    Write-Host "[OK] All checks passed! Deployment is healthy." -ForegroundColor Green
    Write-Host "`nNext step: Verify functions are discovered:" -ForegroundColor Cyan
    Write-Host "  func azure functionapp list-functions $functionApp`n" -ForegroundColor White
} else {
    Write-Host "[FAIL] Found $($issues.Count) issue(s):" -ForegroundColor Red
    foreach ($issue in $issues) {
        Write-Host "  - $issue" -ForegroundColor Yellow
    }
    
    if (-not $AutoFix) {
        Write-Host "`nTo automatically fix these issues, run:" -ForegroundColor Cyan
        Write-Host "  .\azure-health-check.ps1 -AutoFix`n" -ForegroundColor White
    } else {
        Write-Host "`nAuto-fix applied. Wait ~30 seconds for Function App to restart, then run:" -ForegroundColor Cyan
        Write-Host "  func azure functionapp list-functions $functionApp`n" -ForegroundColor White
    }
}
