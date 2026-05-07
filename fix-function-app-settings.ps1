# Fix Function App Connection Strings
# Run this if verification shows connection string mismatches

$ErrorActionPreference = "Stop"
$resourceGroup = "rg-lumovy7q3a"
$storageAccount = "stlumovy7q3a"
$serviceBusNamespace = "sb-lumovy7q3a"
$sqlServer = "sql-lumovy7q3a"
$functionApp = "func-lumovy7q3a"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "FIXING FUNCTION APP CONNECTION STRINGS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Get current connection strings from Azure resources
Write-Host "[1/4] Fetching Storage Account connection string..." -ForegroundColor Yellow
$storageConnectionString = az storage account show-connection-string --name $storageAccount --resource-group $resourceGroup --query connectionString -o tsv
Write-Host "  Retrieved." -ForegroundColor Green

Write-Host "`n[2/4] Fetching Service Bus connection string..." -ForegroundColor Yellow
$serviceBusConnectionString = az servicebus namespace authorization-rule keys list --namespace-name $serviceBusNamespace --resource-group $resourceGroup --name RootManageSharedAccessKey --query primaryConnectionString -o tsv
Write-Host "  Retrieved." -ForegroundColor Green

Write-Host "`n[3/4] Building SQL connection string..." -ForegroundColor Yellow
$sqlConnectionString = "Server=tcp:$sqlServer.database.windows.net,1433;Initial Catalog=ContactsDb;Authentication=Active Directory Default;Encrypt=True;"
Write-Host "  Built." -ForegroundColor Green

# Update Function App settings
Write-Host "`n[4/4] Updating Function App settings..." -ForegroundColor Yellow
Write-Host "  - Updating AzureWebJobsStorage..." -ForegroundColor White
az functionapp config appsettings set --name $functionApp --resource-group $resourceGroup --settings "AzureWebJobsStorage=$storageConnectionString" --output none

Write-Host "  - Updating StorageConnection..." -ForegroundColor White
az functionapp config appsettings set --name $functionApp --resource-group $resourceGroup --settings "StorageConnection=$storageConnectionString" --output none

Write-Host "  - Updating ServiceBusConnection..." -ForegroundColor White
az functionapp config appsettings set --name $functionApp --resource-group $resourceGroup --settings "ServiceBusConnection=$serviceBusConnectionString" --output none

Write-Host "  - Updating SqlConnectionString..." -ForegroundColor White
az functionapp config appsettings set --name $functionApp --resource-group $resourceGroup --settings "SqlConnectionString=$sqlConnectionString" --output none

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "UPDATE COMPLETE" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Function App '$functionApp' is restarting..." -ForegroundColor Yellow
Write-Host "Wait ~30 seconds, then run:" -ForegroundColor Cyan
Write-Host "  func azure functionapp list-functions $functionApp" -ForegroundColor White
Write-Host "`nOr check the Log Stream in the Azure Portal:`n  Monitoring > Log stream`n" -ForegroundColor Cyan
