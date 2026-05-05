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
Blob (archive/<same-filename>.csv) — Append Blob
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
- Azure Functions Core Tools v4 (`brew tap azure/functions && brew install azure-functions-core-tools@4`)

## Running locally

All commands below assume you are inside the project folder:

```bash
cd AzureFunctions-triggers-test
```

1. **Start the infra** (Azurite + SQL Edge + Service Bus emulator):
   ```bash
   docker compose up -d
   docker compose ps
   ```

2. **Create the blob containers** (one-time):
   ```bash
   # Using the Azure CLI (or Storage Explorer, or azcopy — anything that talks to Azurite)
   az storage container create --name incoming  --connection-string "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1"
   az storage container create --name archive   --connection-string "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1"
   ```
   The `ContactsDb` database and its tables are created automatically by the
   Functions host on first run — no manual SQL step required.

3. **Run the Functions host**:
   ```bash
   func start
   ```

4. **Trigger the pipeline** by uploading the sample CSV to `incoming`:
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

All connection strings live in `local.settings.json`:

| Setting                | Purpose                                          |
|------------------------|--------------------------------------------------|
| `AzureWebJobsStorage`  | Runtime storage for the Functions host (Azurite) |
| `StorageConnection`    | Source + archive blob containers                 |
| `ServiceBusConnection` | Both queues                                      |
| `SqlConnectionString`  | ContactsDb                                       |

## Project layout

```
AzureFunctions-triggers-test/
  Functions/
    BlobIngestFunction.cs       # Trigger 1 (blob -> SB)
    RowProcessorFunction.cs     # Trigger 2 (SB -> SQL, tick when done)
    ArchiveFunction.cs          # Trigger 3 (SB -> SQL -> archive blob)
  Models/
    ContactRecord.cs            # CSV row + SB payload + SQL mapping
    FileIngestion.cs            # FileIngestions table row
  Services/
    CsvService.cs               # CsvHelper wrapper
    SqlRepository.cs            # DB bootstrap + CRUD
  Spec/
    spec.md, image.png          # original task spec + diagram
  sample-data/
    contacts.csv                # sample input
  servicebus-emulator/
    Config.json                 # declares the two queues
  Program.cs                    # DI wiring
  host.json                     # SB tuning
  local.settings.json           # connection strings (dev only)
  docker-compose.yml            # Azurite + SQL Edge + SB emulator
  FunctionApp1.csproj           # project file (.NET 8)
  README.md
```
