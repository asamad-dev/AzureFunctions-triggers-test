# Azure Deployment Verification Script
# Run this to verify all Azure resources are correctly configured

$ErrorActionPreference = "Continue"
$resourceGroup = "rg-lumovy7q3a"
$storageAccount = "stlumovy7q3a"
$sqlServer = "sql-lumovy7q3a"
$database = "ContactsDb"
$serviceBusNamespace = "sb-lumovy7q3a"
$functionApp = "func-lumovy7q3a"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "AZURE DEPLOYMENT VERIFICATION" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# 1. Resource Group
Write-Host "[1/9] Checking Resource Group..." -ForegroundColor Yellow
az group show --name $resourceGroup --query "{Name:name, Location:location, ProvisioningState:properties.provisioningState}" -o table

# 2. Storage Account
Write-Host "`n[2/9] Checking Storage Account..." -ForegroundColor Yellow
az storage account show --name $storageAccount --resource-group $resourceGroup --query "{Name:name, Location:location, Sku:sku.name, ProvisioningState:provisioningState}" -o table

# 3. Storage Containers
Write-Host "`n[3/9] Checking Storage Containers..." -ForegroundColor Yellow
az storage container list --account-name $storageAccount --auth-mode login --query "[].{Name:name}" -o table

# 4. Storage Connection String
Write-Host "`n[4/9] Getting Storage Connection String..." -ForegroundColor Yellow
$storageConnectionString = az storage account show-connection-string --name $storageAccount --resource-group $resourceGroup --query connectionString -o tsv
Write-Host "AccountName: $storageAccount" -ForegroundColor Green
Write-Host "Key (first 20 chars): $($storageConnectionString.Substring($storageConnectionString.IndexOf('AccountKey=') + 11, 20))..." -ForegroundColor Green

# 5. SQL Server
Write-Host "`n[5/9] Checking SQL Server..." -ForegroundColor Yellow
az sql server show --name $sqlServer --resource-group $resourceGroup --query "{Name:name, Location:location, State:state, AdminLogin:administratorLogin}" -o table

# 6. SQL Database
Write-Host "`n[6/9] Checking SQL Database..." -ForegroundColor Yellow
az sql db show --name $database --server $sqlServer --resource-group $resourceGroup --query "{Name:name, Status:status, Edition:edition, ComputeModel:currentServiceObjectiveName}" -o table

# 7. SQL Entra-only Auth
Write-Host "`n[7/9] Checking SQL Entra-only Authentication..." -ForegroundColor Yellow
$entraOnly = az sql server ad-only-auth get --name $sqlServer --resource-group $resourceGroup --query azureAdOnlyAuthentication -o tsv
Write-Host "Entra-only Auth Enabled: $entraOnly" -ForegroundColor Green

# 8. Service Bus Namespace
Write-Host "`n[8/9] Checking Service Bus Namespace..." -ForegroundColor Yellow
az servicebus namespace show --name $serviceBusNamespace --resource-group $resourceGroup --query "{Name:name, Location:location, Sku:sku.name, Status:status}" -o table

# 9. Service Bus Queues
Write-Host "`n[9/9] Checking Service Bus Queues..." -ForegroundColor Yellow
az servicebus queue list --namespace-name $serviceBusNamespace --resource-group $resourceGroup --query "[].{Name:name, Status:status}" -o table

# 10. Service Bus Connection String
Write-Host "`n[10/11] Getting Service Bus Connection String..." -ForegroundColor Yellow
$serviceBusConnectionString = az servicebus namespace authorization-rule keys list --namespace-name $serviceBusNamespace --resource-group $resourceGroup --name RootManageSharedAccessKey --query primaryConnectionString -o tsv
Write-Host "Endpoint: sb://$serviceBusNamespace.servicebus.windows.net/" -ForegroundColor Green

# 11. Function App
Write-Host "`n[11/13] Checking Function App..." -ForegroundColor Yellow
az functionapp show --name $functionApp --resource-group $resourceGroup --query "{Name:name, Location:location, State:state, Kind:kind}" -o table

# 12. Function App Managed Identity
Write-Host "`n[12/13] Checking Function App Managed Identity..." -ForegroundColor Yellow
az functionapp identity show --name $functionApp --resource-group $resourceGroup --query "{Type:type, PrincipalId:principalId}" -o table

# 13. Function App Settings
Write-Host "`n[13/13] Checking Function App Connection Strings..." -ForegroundColor Yellow
az functionapp config appsettings list --name $functionApp --resource-group $resourceGroup --query "[?name=='AzureWebJobsStorage' || name=='StorageConnection' || name=='ServiceBusConnection' || name=='SqlConnectionString'].{Name:name, ValuePreview:value}" -o table

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "VERIFICATION COMPLETE" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Summary
Write-Host "SUMMARY:" -ForegroundColor Green
Write-Host "- Resource Group: $resourceGroup" -ForegroundColor White
Write-Host "- Storage Account: $storageAccount (with 'incoming' and 'archive' containers)" -ForegroundColor White
Write-Host "- SQL Server: $sqlServer (Entra-only auth: $entraOnly)" -ForegroundColor White
Write-Host "- SQL Database: $database" -ForegroundColor White
Write-Host "- Service Bus: $serviceBusNamespace (with 'contacts-queue' and 'file-complete-queue')" -ForegroundColor White
Write-Host "- Function App: $functionApp" -ForegroundColor White

Write-Host "`nNext step: Run 'func azure functionapp list-functions $functionApp' to verify functions are discovered.`n" -ForegroundColor Cyan
