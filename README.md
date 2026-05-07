# Lumovy — Azure Functions CSV Pipeline

Event-driven pipeline built with three Azure Functions that ingests a CSV of
contacts, fans rows through a Service Bus queue into SQL, then archives the
finished file back to blob storage.

## Architecture

```
Blob (incoming/*.csv)
        │
        ▼
┌────────────────────┐      INSERT FileIngestions
│ BlobIngestFunction │────────────────────────────► SQL (ContactsDb)
│    (Trigger 1)     │
└────────────────────┘
        │  one message per row
        ▼
   contacts-queue  (Service Bus)
        │
        ▼
┌────────────────────┐      INSERT Contacts
│ RowProcessorFn     │────────────────────────────► SQL (ContactsDb)
│    (Trigger 2)     │◄─── atomic increment of
└────────────────────┘     FileIngestions.ProcessedRows
        │  tick when ProcessedRows == RowCount
        ▼
  file-complete-queue (Service Bus)
        │
        ▼
┌────────────────────┐      SELECT Contacts
│ ArchiveFunction    │◄────────────────────────── SQL (ContactsDb)
│    (Trigger 3)     │
└────────────────────┘
        │
        ▼
Blob (archive/<same-filename>.csv)
```

### Idempotency

If a file with the same `(FileName, RowCount)` pair is re-uploaded, the
pipeline **skips** the ingest entirely (`SqlRepository.IngestionExistsAsync`).
Per-row duplicate Service Bus deliveries are also safe: the combined
insert+increment runs in a single atomic SQL statement.

## Data model

One SQL database (`ContactsDb`), two tables — both auto-created on first run
by `SqlRepository.EnsureSchemaAsync`.

| Table            | Purpose                                         |
|------------------|-------------------------------------------------|
| `FileIngestions` | Tracks `FileName`, `RowCount`, progress, status |
| `Contacts`       | Stores the parsed CSV rows                      |

CSV schema is fixed: `FirstName, LastName, Email, PhoneNumber` (with header).

## Prerequisites

- Docker Desktop
- .NET 8 SDK
- Azure Functions Core Tools v4
  - macOS: `brew tap azure/functions && brew install azure-functions-core-tools@4`
  - Windows: download the MSI from https://github.com/Azure/azure-functions-core-tools/releases/latest

## Running locally

All commands below assume you are inside the project folder.

1. **Start the infra** (Azurite + SQL Edge + Service Bus emulator):
   ```bash
   docker compose -f infra/docker-compose.yml up -d
   ```

2. **Create the blob containers** (one-time):
   ```bash
   az storage container create --name incoming --connection-string "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1"
   az storage container create --name archive  --connection-string "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1"
   ```
   The `ContactsDb` database and tables are created automatically on first run.

3. **Start the Functions host**:
   ```bash
   func start
   ```

4. **Upload the sample CSV** to trigger the pipeline:
   ```bash
   az storage blob upload \
     --container-name incoming \
     --file sample-data/contacts.csv \
     --name contacts.csv \
     --connection-string "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1"
   ```

5. **Inspect results**:
   ```bash
   # SQL
   docker exec -it lumovy-sqledge /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'Strong!Passw0rd' \
     -Q "SELECT * FROM ContactsDb.dbo.FileIngestions; SELECT * FROM ContactsDb.dbo.Contacts;"

   # Archive blob
   az storage blob download --container-name archive --name contacts.csv --file /tmp/archived.csv \
     --connection-string "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1"
   cat /tmp/archived.csv
   ```

## Configuration

Local connection strings live in `local.settings.json` (never committed):

| Setting                | Purpose                                          |
|------------------------|--------------------------------------------------|
| `AzureWebJobsStorage`  | Runtime storage for the Functions host (Azurite) |
| `StorageConnection`    | Source + archive blob containers                 |
| `ServiceBusConnection` | Both Service Bus queues                          |
| `SqlConnectionString`  | ContactsDb                                       |

## Project layout

```
AzureFunctions-triggers-test/
  Functions/
    BlobIngestFunction.cs       # Trigger 1 — blob -> Service Bus
    RowProcessorFunction.cs     # Trigger 2 — Service Bus -> SQL
    ArchiveFunction.cs          # Trigger 3 — Service Bus -> SQL -> archive blob
  Models/
    ContactRecord.cs            # CSV row, SB payload, SQL mapping
    FileIngestion.cs            # FileIngestions table row
  Services/
    CsvService.cs               # CsvHelper wrapper
    SqlRepository.cs            # DB bootstrap + CRUD
  docs/
    spec.md, image.png          # original task spec
    azure-deployment.md         # Azure resource creation guide
  infra/
    docker-compose.yml          # Azurite + SQL Edge + Service Bus emulator
    servicebus-emulator/
      Config.json               # local SB emulator queue config
  scripts/
    azure-health-check.ps1      # pre-deploy health check (see PowerShell Scripts below)
    deploy.ps1                  # automated full deployment
  sample-data/
    contacts.csv                # sample input
  Program.cs                    # DI wiring
  host.json                     # Service Bus concurrency tuning
  local.settings.json           # connection strings (local dev only, not committed)
  FunctionApp1.csproj           # project file (.NET 8 isolated worker)
```

## Azure deployment

See **[docs/azure-deployment.md](docs/azure-deployment.md)** for the complete step-by-step guide to provisioning all Azure resources and deploying the code.

### Known deployment issue — solution file interferes with `func publish`

If a `.slnx` or `.sln` solution file exists alongside the project, running
`func azure functionapp publish` directly from the project root **silently
omits** the `functions.metadata` file from the deployment zip. Without that
file, the Azure Functions runtime reports `0 functions found` even though the
deployment itself succeeds.

**Always deploy using the clean publish folder method:**

```powershell
dotnet publish FunctionApp1.csproj --configuration Release --output ./publish
cd publish
func azure functionapp publish func-<base> --no-build --dotnet-isolated
cd ..
```

Verify after deploy:
```powershell
func azure functionapp list-functions func-<base>
```

Expected output:
```
Functions in func-<base>:
    ArchiveFunction - [serviceBusTrigger]
    BlobIngestFunction - [blobTrigger]
    RowProcessorFunction - [serviceBusTrigger]
```

## PowerShell scripts

These scripts target the deployed Azure resources. All require `az login` and
Contributor access on the resource group. Edit the variable block at the top
of each file if your resource names differ.

| Script | Purpose |
|--------|---------|
| `scripts/azure-health-check.ps1` | Checks all resources are provisioned and running. With `-AutoFix` it also creates missing blob containers and refreshes stale connection strings in the Function App. Run this before every deployment. |
| `scripts/deploy.ps1` | Runs `azure-health-check.ps1 -AutoFix`, then builds, publishes, and deploys the project. Always run from the project root: `.\scripts\deploy.ps1` |
