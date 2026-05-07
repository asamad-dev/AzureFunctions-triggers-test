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

Write-Host "`n╔════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  AZURE DEPLOYMENT HEALTH CHECK         ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════╝`n" -ForegroundColor Cyan

$issues = @()

# 1. Resource Group
Write-Host "✓ Checking Resource Group..." -ForegroundColor Yellow
$rg = az group show --name $resourceGroup --query "{Name:name, Location:location, State:properties.provisioningState}" -o json 2>&1 | ConvertFrom-Json
if ($rg.State -eq "Succeeded") {
    Write-Host "  ✓ Resource Group: $($rg.Name) ($($rg.Location))" -ForegroundColor Green
} else {
    Write-Host "  ✗ Resource Group issue detected" -ForegroundColor Red
    $issues += "Resource Group not in Succeeded state"
}

# 2. Storage Account
Write-Host "`n✓ Checking Storage Account..." -ForegroundColor Yellow
$storage = az storage account show --name $storageAccount --resource-group $resourceGroup --query "{Name:name, Location:location, State:provisioningState}" -o json 2>&1 | ConvertFrom-Json
if ($storage.State -eq "Succeeded") {
    Write-Host "  ✓ Storage Account: $($storage.Name) ($($storage.Location))" -ForegroundColor Green
} else {
    Write-Host "  ✗ Storage Account issue detected" -ForegroundColor Red
    $issues += "Storage Account not provisioned"
}

# 3. Storage Containers
Write-Host "`n✓ Checking Storage Containers..." -ForegroundColor Yellow
$containers = az storage container list --account-name $storageAccount --auth-mode login --query "[].name" -o json 2>&1 | ConvertFrom-Json
$hasIncoming = $containers -contains "incoming"
$hasArchive = $containers -contains "archive"

if ($hasIncoming -and $hasArchive) {
    Write-Host "  ✓ Containers: incoming, archive" -ForegroundColor Green
} else {
    Write-Host "  ✗ Missing containers:" -ForegroundColor Red
    if (-not $hasIncoming) { Write-Host "    - incoming" -ForegroundColor Red; $issues += "Missing 'incoming' container" }
    if (-not $hasArchive) { Write-Host "    - archive" -ForegroundColor Red; $issues += "Missing 'archive' container" }
    
    if ($AutoFix) {
        Write-Host "`n  → Auto-fixing: Creating missing containers..." -ForegroundColor Cyan
        if (-not $hasIncoming) {
            az storage container create --name incoming --account-name $storageAccount --auth-mode login --output none
            Write-Host "    ✓ Created 'incoming'" -ForegroundColor Green
        }
        if (-not $hasArchive) {
            az storage container create --name archive --account-name $storageAccount --auth-mode login --output none
            Write-Host "    ✓ Created 'archive'" -ForegroundColor Green
        }
    }
}

# 4. Get Storage Connection String
$storageConnectionString = az storage account show-connection-string --name $storageAccount --resource-group $resourceGroup --query connectionString -o tsv

# 5. SQL Server
Write-Host "`n✓ Checking SQL Server..." -ForegroundColor Yellow
$sql = az sql server show --name $sqlServer --resource-group $resourceGroup --query "{Name:name, State:state}" -o json 2>&1 | ConvertFrom-Json
if ($sql.State -eq "Ready") {
    Write-Host "  ✓ SQL Server: $($sql.Name)" -ForegroundColor Green
} else {
    Write-Host "  ✗ SQL Server not ready" -ForegroundColor Red
    $issues += "SQL Server not in Ready state"
}

# 6. SQL Database
Write-Host "`n✓ Checking SQL Database..." -ForegroundColor Yellow
$db = az sql db show --name $database --server $sqlServer --resource-group $resourceGroup --query "{Name:name, Status:status}" -o json 2>&1 | ConvertFrom-Json
Write-Host "  ✓ Database: $($db.Name) (Status: $($db.Status))" -ForegroundColor Green

# 7. Service Bus
Write-Host "`n✓ Checking Service Bus..." -ForegroundColor Yellow
$sb = az servicebus namespace show --name $serviceBusNamespace --resource-group $resourceGroup --query "{Name:name, Status:status}" -o json 2>&1 | ConvertFrom-Json
if ($sb.Status -eq "Active") {
    Write-Host "  ✓ Service Bus: $($sb.Name)" -ForegroundColor Green
} else {
    Write-Host "  ✗ Service Bus not active" -ForegroundColor Red
    $issues += "Service Bus not Active"
}

# 8. Service Bus Queues
Write-Host "`n✓ Checking Service Bus Queues..." -ForegroundColor Yellow
$queues = az servicebus queue list --namespace-name $serviceBusNamespace --resource-group $resourceGroup --query "[].name" -o json 2>&1 | ConvertFrom-Json
$hasContactsQueue = $queues -contains "contacts-queue"
$hasFileCompleteQueue = $queues -contains "file-complete-queue"

if ($hasContactsQueue -and $hasFileCompleteQueue) {
    Write-Host "  ✓ Queues: contacts-queue, file-complete-queue" -ForegroundColor Green
} else {
    Write-Host "  ✗ Missing queues" -ForegroundColor Red
    if (-not $hasContactsQueue) { $issues += "Missing 'contacts-queue'" }
    if (-not $hasFileCompleteQueue) { $issues += "Missing 'file-complete-queue'" }
}

# 9. Get Service Bus Connection String
$serviceBusConnectionString = az servicebus namespace authorization-rule keys list --namespace-name $serviceBusNamespace --resource-group $resourceGroup --name RootManageSharedAccessKey --query primaryConnectionString -o tsv

# 10. Function App
Write-Host "`n✓ Checking Function App..." -ForegroundColor Yellow
$func = az functionapp show --name $functionApp --resource-group $resourceGroup --query "{Name:name, State:state}" -o json 2>&1 | ConvertFrom-Json
if ($func.State -eq "Running") {
    Write-Host "  ✓ Function App: $($func.Name) (Running)" -ForegroundColor Green
} else {
    Write-Host "  ✗ Function App not running (State: $($func.State))" -ForegroundColor Red
    $issues += "Function App not Running"
}

# 11. Function App Settings
Write-Host "`n✓ Checking Function App Connection Strings..." -ForegroundColor Yellow
$settings = az functionapp config appsettings list --name $functionApp --resource-group $resourceGroup --query "[?name=='AzureWebJobsStorage' || name=='StorageConnection' || name=='ServiceBusConnection' || name=='SqlConnectionString']" -o json 2>&1 | ConvertFrom-Json

$currentAzureWebJobsStorage = ($settings | Where-Object { $_.name -eq "AzureWebJobsStorage" }).value
$currentStorageConnection = ($settings | Where-Object { $_.name -eq "StorageConnection" }).value
$currentServiceBusConnection = ($settings | Where-Object { $_.name -eq "ServiceBusConnection" }).value
$currentSqlConnectionString = ($settings | Where-Object { $_.name -eq "SqlConnectionString" }).value

$expectedSqlConnectionString = "Server=tcp:$sqlServer.database.windows.net,1433;Initial Catalog=ContactsDb;Authentication=Active Directory Default;Encrypt=True;"

$settingsOk = $true

# Extract AccountKey from connection strings for comparison
$currentStorageKey = if ($currentAzureWebJobsStorage -match 'AccountKey=([^;]+)') { $matches[1] } else { "" }
$expectedStorageKey = if ($storageConnectionString -match 'AccountKey=([^;]+)') { $matches[1] } else { "" }

if ($currentStorageKey -ne $expectedStorageKey) {
    Write-Host "  ✗ AzureWebJobsStorage has wrong key" -ForegroundColor Red
    $issues += "AzureWebJobsStorage key mismatch"
    $settingsOk = $false
}

$currentStorageKey2 = if ($currentStorageConnection -match 'AccountKey=([^;]+)') { $matches[1] } else { "" }
if ($currentStorageKey2 -ne $expectedStorageKey) {
    Write-Host "  ✗ StorageConnection has wrong key" -ForegroundColor Red
    $issues += "StorageConnection key mismatch"
    $settingsOk = $false
}

if ($currentServiceBusConnection -ne $serviceBusConnectionString) {
    Write-Host "  ✗ ServiceBusConnection mismatch" -ForegroundColor Red
    $issues += "ServiceBusConnection mismatch"
    $settingsOk = $false
}

if ($currentSqlConnectionString -ne $expectedSqlConnectionString) {
    Write-Host "  ✗ SqlConnectionString mismatch" -ForegroundColor Red
    $issues += "SqlConnectionString mismatch"
    $settingsOk = $false
}

if ($settingsOk) {
    Write-Host "  ✓ All connection strings are correct" -ForegroundColor Green
} elseif ($AutoFix) {
    Write-Host "`n  → Auto-fixing: Updating connection strings..." -ForegroundColor Cyan
    az functionapp config appsettings set --name $functionApp --resource-group $resourceGroup --settings "AzureWebJobsStorage=$storageConnectionString" --output none
    az functionapp config appsettings set --name $functionApp --resource-group $resourceGroup --settings "StorageConnection=$storageConnectionString" --output none
    az functionapp config appsettings set --name $functionApp --resource-group $resourceGroup --settings "ServiceBusConnection=$serviceBusConnectionString" --output none
    az functionapp config appsettings set --name $functionApp --resource-group $resourceGroup --settings "SqlConnectionString=$expectedSqlConnectionString" --output none
    Write-Host "    ✓ Connection strings updated (Function App restarting...)" -ForegroundColor Green
}

# Summary
Write-Host "`n╔════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  HEALTH CHECK SUMMARY                  ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════╝`n" -ForegroundColor Cyan

if ($issues.Count -eq 0) {
    Write-Host "✓ All checks passed! Deployment is healthy." -ForegroundColor Green
    Write-Host "`nNext step: Verify functions are discovered:" -ForegroundColor Cyan
    Write-Host "  func azure functionapp list-functions $functionApp`n" -ForegroundColor White
} else {
    Write-Host "✗ Found $($issues.Count) issue(s):" -ForegroundColor Red
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
