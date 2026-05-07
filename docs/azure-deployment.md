# Azure Deployment Runbook

End-to-end steps to deploy this CSV pipeline to Azure using the **Azure
Portal**. All instructions reflect the portal UI as of late 2025 / early 2026.

> **Azure-only project.** This project no longer has a local Docker/emulator
> stack (Azurite + SQL Edge + Service Bus emulator). All development and
> testing happens against real Azure resources provisioned in the steps
> below. The files that made up the retired local stack
> (`docker-compose.yml`, `servicebus-emulator/Config.json`, the Docker parts
> of `README.md`) can be deleted — see *Retire the local dev stack* near the
> end of this doc.

The deployment is split into two phases per the spec:

- **Phase 1**: Get the pipeline working in Azure. **SQL** is on managed
  identity from day one (Entra-only auth on the server). **Storage** and
  **Service Bus** start with connection strings.
- **Phase 2**: Migrate Storage and Service Bus to **managed identity** too,
  so no secrets remain in app settings.

---

## Resources we will create

| Resource                  | Purpose                                  | Tier                          |
|---------------------------|------------------------------------------|-------------------------------|
| Resource group            | Logical container for everything         | n/a                           |
| Storage account           | `incoming` + `archive` blob containers AND the Function host's runtime storage | Standard LRS, StorageV2 |
| Azure SQL server + DB     | `ContactsDb` (FileIngestions, Contacts)  | **Free offer** (Serverless GP, auto-pause), Entra-only auth |
| Service Bus namespace     | `contacts-queue`, `file-complete-queue`  | **Standard** (Basic also works, see note below) |
| Application Insights      | Logs / metrics for the Function app      | Workspace-based               |
| Log Analytics workspace   | Backing store for App Insights           | Pay-as-you-go                 |
| Function App              | Hosts the three triggers                 | **Consumption (classic)**, Linux, .NET 8 isolated |

> **Tier note for Service Bus**: Microsoft Entra (managed identity)
> authentication works on **Basic, Standard and Premium**. We pick **Standard**
> because it's the same shape as production for almost no cost difference and
> it lets you add topics/sessions later without re-creating the namespace.

---

## Phase 0 - Prerequisites

- An Azure subscription with **Owner** or **Contributor + User Access
  Administrator** on the subscription or target resource group (the second
  role is needed to assign RBAC for managed identity in Phase 2).
- **Azure CLI** installed locally, then `az login` to sign in:
  - **macOS**: `brew install azure-cli`
  - **Windows (PowerShell, Admin)**: `winget install -e --id Microsoft.AzureCLI`
    (or download the MSI from <https://aka.ms/installazurecliwindows>)
  - **Linux**: see <https://learn.microsoft.com/cli/azure/install-azure-cli-linux>
- **Azure Functions Core Tools v4** — needed by `func azure functionapp
  publish` to build the project on your machine and zip-deploy it to Azure:
  - **macOS**: `brew tap azure/functions && brew install azure-functions-core-tools@4`
  - **Windows**: download the MSI from
    <https://github.com/Azure/azure-functions-core-tools/releases/latest>
    (`Azure.Functions.Cli.win-x64.<version>.msi`) and run it. Alternatives:
    `choco install azure-functions-core-tools-4 -y` if you have Chocolatey, or
    `npm install -g azure-functions-core-tools@4 --unsafe-perm true` if you
    already have Node.js.
- **.NET 8 SDK** — `dotnet build` must succeed from the project folder, since
  `func azure functionapp publish` uses it under the hood. There is no
  `func start` step — iteration happens by re-deploying to Azure and reading
  logs from Application Insights.

> **Windows tip**: after any MSI install (Azure CLI, Functions Core Tools,
> Node.js), **open a new PowerShell window** before running the new command.
> The MSI writes to the system PATH but already-open shells keep their
> cached PATH. Alternatively, refresh PATH in-place:
>
> ```powershell
> $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
> ```

Pick a short, unique **base name** now and stick to it. Examples in this doc
use `lumovy` plus a 4-char random suffix, e.g. `lumovy7q3a`. Replace it
everywhere you see `<base>`.

> **Shell convention used in this doc**: code blocks tagged `bash` are for
> **macOS/Linux** (zsh/bash). On **Windows PowerShell**, the same `az` /
> `func` / `dotnet` commands work — only the line-continuation character and
> path separator differ:
>
> | Token            | bash / zsh   | PowerShell        | cmd.exe |
> |------------------|--------------|-------------------|---------|
> | Line continuation | `\` at EOL  | `` ` `` (backtick) at EOL | `^` at EOL |
> | Path separator    | `/`         | `\` or `/`         | `\`     |
>
> Where the difference is non-trivial (multi-line `az` commands, project
> folder paths) both variants are shown side by side.

---

## Phase 1 - Create and wire up the Azure resources

### 1.1 Create a resource group

1. Portal home → top search bar → **Resource groups** → **+ Create**.
2. **Subscription**: your subscription.
3. **Resource group**: `rg-<base>` (e.g. `rg-lumovy7q3a`).
4. **Region**: **North Europe**. Use this same region for every resource
   below. The SQL Database **Free offer** is region-restricted per
   subscription and capacity shifts day to day — North Europe is the most
   reliable choice we have tested for new subscriptions. If step 1.3 later
   rejects North Europe with *"subscription does not have access to create
   a server in the selected region"*, delete this empty RG and retry the
   creation in *East US 2*, *West US 2*, or *West Europe*.
5. **Review + create** → **Create**.

### 1.2 Create the storage account

This account holds two things at once: the source/archive blob containers AND
the Function App's own runtime state.

1. Top search bar → **Storage accounts** → **+ Create**.
2. **Basics** tab:
   - **Resource group**: `rg-<base>`.
   - **Storage account name**: `st<base>` (3-24 lowercase letters/digits, e.g.
     `stlumovy7q3a`).
   - **Region**: same region as the RG.
   - **Primary service**: *Azure Blob Storage or Azure Data Lake Storage Gen 2*.
   - **Performance**: **Standard**.
   - **Redundancy**: **Locally-redundant storage (LRS)**.
3. **Advanced** tab: leave defaults (TLS 1.2 minimum, hierarchical namespace OFF).
4. **Networking**: **Enable public access from all networks** (simplest for
   dev; tighten later).
5. **Review** → **Create**. Wait ~30s for deployment.

#### Create the two containers

1. Open the new storage account → left nav: **Data storage** → **Containers**.
2. **+ Container** → Name: `incoming` → **Create**.
3. **+ Container** → Name: `archive` → **Create**.

#### Grab the connection string (used in Phase 1, removed in Phase 2)

1. Left nav: **Security + networking** → **Access keys**.
2. Click **Show** next to *key1* → copy **Connection string**.
3. Save it as `STORAGE_CONNECTION` in your scratchpad.

### 1.3 Create the Azure SQL database (Free offer, Entra-only auth)

We use the **Free offer** — 100,000 vCore-seconds + 32 GB data + 32 GB
backup per month for the lifetime of the subscription, on Serverless
General Purpose with auto-pause. The DB costs nothing while idle. There is
a ~30-60 second cold-start the first time it is queried after pausing;
subsequent calls are fast.

We also use **Microsoft Entra-only authentication**: there is no `sqladmin`
login, no SQL password to manage. The Function App connects to SQL using
its **system-assigned managed identity** from day one (the Function App
MI + the database user that maps to it are created in steps **1.5b** and
**1.5c**).

1. Top search bar → **Azure SQL** → **+ Create** → from the dropdown pick
   **SQL database (Free offer)**.
2. **Basics** tab:
   - **Subscription**: your subscription.
   - **Resource Group**: `rg-<base>`.
   - **Database name**: `ContactsDb`.
   - **Server**: click **Create new**:
     - **Server name**: `sql-<base>` (globally unique; the portal must show
       a green check).
     - **Location**: **same region as the resource group** — **North
       Europe** if you followed step 1.1. If Azure rejects this region
       with the red *"subscription does not have access to create a server
       in the selected region"* error, see step 1.1 for fallback regions.
     - **Authentication method**: **Use Microsoft Entra-only authentication**.
     - **Set Microsoft Entra admin**: pick yourself (or a security group
       you belong to). You will use this identity to run the one-off T-SQL
       grants in step 1.5c.
     - **OK**.
   - The Free offer pre-fills compute, storage, redundancy and auto-pause
     — leave them as-is. (Click **Advanced configuration** if you want to
     inspect or override them.)
3. **Review + create** → **Create**. Wait ~3-5 min.

> The `SqlRepository.EnsureSchemaAsync` call in our code creates the
> `FileIngestions` and `Contacts` tables on first run, so no manual DDL is
> needed — but we *do* still need a one-off T-SQL run to register the
> Function App's identity as a database user. That happens in step 1.5c,
> after the Function App and its managed identity exist.

### 1.4 Create the Service Bus namespace and queues

1. Top search bar → **Service Bus** → **+ Create**.
2. **Basics** tab:
   - **Resource group**: `rg-<base>`.
   - **Namespace name**: `sb-<base>` (globally unique).
   - **Location**: same region.
   - **Pricing tier**: **Standard**.
3. **Review + create** → **Create**. Wait ~1-2 min.
4. Open the new namespace → left nav: **Entities** → **Queues** → **+ Queue**.
   - **Name**: `contacts-queue`.
   - **Max queue size**: 1 GB.
   - **Message time to live**: `1:00:00:00` (1 day) — anything > a few minutes is fine.
   - **Lock duration**: `0:01:00` (1 minute) — ample for our row-processing workload.
   - **Max delivery count**: `10`.
   - Leave the rest at default (no sessions, no duplicate detection).
   - **Create**.
5. Repeat **+ Queue** for `file-complete-queue` with the same settings.

#### Grab the SAS connection string

1. Namespace → left nav: **Settings** → **Shared access policies**.
2. Click **RootManageSharedAccessKey** → copy **Primary Connection String**.
3. Save as `SERVICEBUS_CONNECTION`.

### 1.5 Create the Function App

> The portal's create flow shows multiple hosting tiles (Flex Consumption,
> Premium, App Service plan, Container Apps, **Consumption (Windows)**).
> Pick the rightmost **Consumption (Windows)** tile. Despite the label, this
> is the classic Consumption plan our spec calls for. The OS is fixed to
> **Windows** by this tile choice — that's actually the safer pick because
> only *Linux* Consumption is being retired (30 September 2028); Windows
> Consumption is not on a retirement track. For our 3 triggers (BlobTrigger,
> ServiceBusTrigger × 2), Windows and Linux behave identically.
>
> **Don't pick Flex Consumption** even though Microsoft now markets it as
> the default: Flex's blob trigger only supports the *Event Grid source*,
> but our `BlobIngestFunction` uses the polling-based `[BlobTrigger]`.
> Migrating to Flex would require refactoring the trigger to Event Grid +
> provisioning an Event Grid system topic and subscription — doable but out
> of scope for this spec.

1. Top search bar → **Function App** → **+ Create**.
2. On the **Select a hosting option** screen, pick **Consumption (Windows)**
   → **Select**.
3. **Basics** tab:
   - **Subscription**: your subscription.
   - **Resource Group**: `rg-<base>`.
   - **Function App name**: `func-<base>` (globally unique). With *Secure
     unique default hostname* on (default), the URL becomes
     `https://func-<base>-<random>.<region>-01.azurewebsites.net` — fine
     for us since we have no HTTP triggers.
   - **Operating System**: **Windows** (fixed by the tile choice).
   - **Runtime stack**: **.NET**.
   - **Version**: **8 (LTS), Isolated worker model**.
   - **Region**: **North Europe** (same as everything else).
4. **Networking** tab: leave **Enable public access** = On.
5. **Monitoring** tab:
   - **Enable Application Insights**: **Yes**.
   - **Application Insights**: **Create new** → name `appi-<base>` → choose
     or create a Log Analytics workspace `log-<base>` in the same region.
6. **Durable Functions** tab:
   - **Backend providers**: **Bring your own: Azure Storage**. (We don't
     use Durable Functions, but this is the free default. Don't pick
     *Azure managed: Durable Task Scheduler* — that provisions a paid
     resource we don't need.)
7. **Deployment** tab: **Disable** *Continuous deployment* for now. We'll
   deploy once via `func azure functionapp publish` in step 1.7. You can
   come back later and enable GitHub Actions via **Deployment Center** if
   you want CI/CD.
8. **Authentication** tab: this is *resource authentication* (how the
   Function App authenticates to its three host dependencies — host
   storage, Azure Files, App Insights), **not** App Service / HTTP auth.
   Leave the dropdowns at **Secrets** for now. Phase 2 of this doc
   migrates `AzureWebJobsStorage` to managed identity later. If you'd
   rather skip that future step, switch *Host storage* and *Application
   Insights* to **Managed Identity** here — Azure will enable system-
   assigned MI on the Function App automatically and assign the required
   RBAC roles. *Azure Files* is locked to Secrets on Windows Consumption
   and can't be changed.
9. **Tags** tab: skip.
10. **Review + create** → **Create**. Wait ~2-3 min.

> **Quota gotcha** — if **Review + create** fails with
> `SubscriptionIsOverQuotaForSku` and *Current Limit (Dynamic VMs): 0*, your
> subscription has zero Consumption-plan capacity in this region (common on
> free/trial subs). Two fixes:
>
> 1. **Request a quota increase** (preferred, often auto-approved in
>    minutes): portal → **Subscriptions** → your sub → **Settings** →
>    **Usage + quotas**. Filter **Provider** = `Microsoft.Web`,
>    **Location** = your region. Edit the **Dynamic VMs** row → new limit
>    `10` → **Save**. Wait for approval, then retry the create.
> 2. **Pick a different region** for the Function App only (e.g. West
>    Europe). Cross-region traffic to your North Europe storage / SQL /
>    Service Bus is fine for this workload (~10-20 ms latency, negligible
>    egress cost), just messier to manage.

> **Storage note**: the new Consumption (Windows) wizard does **not** have
> a Storage tab where you'd pick the existing `st<base>` account. Instead
> it auto-creates a separate storage account (something like
> `<rgname><randomsuffix>`) just for the Function App's runtime state
> (`AzureWebJobsStorage`, deployment package, host leases). Let it. You'll
> end up with two storage accounts:
>
> - **`st<base>`** (created in 1.2) — holds your `incoming` + `archive`
>   blob containers, referenced via the `StorageConnection` app setting in
>   step 1.6.
> - **`<auto-generated>`** — holds the Function App host's internal state
>   only. You never touch its containers; they're managed by the Functions
>   runtime.
>
> This separation of app data from host state is the cleaner pattern Azure
> recommends in production. Don't try to merge them.

### 1.5b Enable system-assigned managed identity on the Function App

We need the Function App's identity *before* step 1.5c (which grants it SQL
access) and before configuring `SqlConnectionString` in step 1.6.

1. Function App → left nav: **Settings** → **Identity**.
2. **System assigned** tab → **Status**: **On** → **Save** → **Yes**.
3. Copy the **Object (principal) ID** that appears — useful for auditing
   but not strictly required (the next step references the Function App by
   its display name).

### 1.5c Grant the Function App SQL access

The Function App's identity needs a database user and the right roles to:

- read/write rows (`db_datareader`, `db_datawriter`),
- and run `CREATE TABLE` from `EnsureSchemaAsync` (`db_ddladmin`).

1. Azure SQL → your database `ContactsDb` → left nav: **Query editor (preview)**.
2. Sign in with **Microsoft Entra single sign-on** as the Entra admin you
   set in step 1.3.
3. Run the `CREATE USER` statement first (on its own), replacing `func-<base>`
   with your Function App's exact name:
   ```sql
   CREATE USER [func-<base>] FROM EXTERNAL PROVIDER;
   ```
4. Then run the three role grants in a **separate** execution:
   ```sql
   ALTER ROLE db_datareader ADD MEMBER [func-<base>];
   ALTER ROLE db_datawriter ADD MEMBER [func-<base>];
   ALTER ROLE db_ddladmin   ADD MEMBER [func-<base>];
   ```
   > **Why separately?** If you paste all four lines at once and
   > `CREATE USER` fails (e.g. the user already exists from a previous
   > attempt), the Portal's query editor aborts the whole batch and the
   > `ALTER ROLE` lines never run. Running them in two steps avoids this.
5. Confirm the user and roles landed:
   ```sql
   SELECT dp.name, dp.type_desc, rp.name AS role
   FROM sys.database_role_members drm
   JOIN sys.database_principals dp ON dp.principal_id = drm.member_principal_id
   JOIN sys.database_principals rp ON rp.principal_id = drm.role_principal_id
   WHERE dp.name = 'func-<base>';
   ```
   You should see three rows: `db_datareader`, `db_datawriter`, `db_ddladmin`.

### 1.6 Add the connection-string app settings

1. Open the Function App → left nav: **Settings** → **Environment variables**
   → tab **App settings**.
2. **First, verify `AzureWebJobsStorage` exists.** Type `azurewebjobs` into
   the search box. You should see a setting named `AzureWebJobsStorage`
   with a connection-string value. If it's **missing** (the wizard
   sometimes skips it, especially when the Function App region differs
   from the rest of your resources), add it now using the same value as
   `<STORAGE_CONNECTION>` from step 1.2. Without this setting,
   `func azure functionapp publish` fails with *"missing host storage
   configuration"*.
3. Click **+ Add** four (or five if AzureWebJobsStorage was missing) times
   (or use **Advanced edit** for bulk JSON):

   | Name                       | Value                                                                                                                                |
   |----------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
   | `AzureWebJobsStorage`      | `<STORAGE_CONNECTION>` (only if missing — see step 2 above)                                                                         |
   | `StorageConnection`        | `<STORAGE_CONNECTION>` (from step 1.2)                                                                                              |
   | `ServiceBusConnection`     | `<SERVICEBUS_CONNECTION>` (from step 1.4)                                                                                           |
   | `SqlConnectionString`      | `Server=tcp:sql-<base>.database.windows.net,1433;Initial Catalog=ContactsDb;Authentication=Active Directory Default;Encrypt=True;` |
   | `WEBSITE_RUN_FROM_PACKAGE` | `1` (only if not present already)                                                                                                   |

4. **Click Apply** at the bottom of the Environment variables page (not
   just OK in the per-setting dialog) → **Confirm** the app restart. Wait
   ~30 seconds before deploying.

   Notes:
   - `Microsoft.Data.SqlClient` 5.x picks up the Function App's managed
     identity automatically when it sees `Authentication=Active Directory
     Default`, so no code change is needed for SQL.
   - Leave the auto-populated settings (`APPLICATIONINSIGHTS_CONNECTION_STRING`,
     `AzureWebJobsSecretStorageType`, `FUNCTIONS_EXTENSION_VERSION`,
     `FUNCTIONS_WORKER_RUNTIME`, `WEBSITE_USE_PLACEHOLDER_DOTNETISOLATED`)
     alone.

### 1.7 Verify deployment readiness (optional but recommended)

Before deploying, you can verify all Azure resources are correctly configured
using the provided PowerShell verification scripts:

```powershell
# Windows PowerShell - Quick health check with auto-fix
cd C:\path\to\AzureFunctions-triggers-test
.\azure-health-check.ps1 -AutoFix
```

This script verifies:
- All resources exist and are in the correct state
- Storage containers (`incoming`, `archive`) exist
- Connection strings in Function App settings match current keys
- Auto-fixes common issues (missing containers, stale connection strings)

**Alternative scripts** (if you prefer manual verification):
- `.\verify-azure-deployment.ps1` — Read-only verification, no changes
- `.\create-storage-containers.ps1` — Create missing containers only
- `.\fix-function-app-settings.ps1` — Update connection strings only

### 1.8 Deploy the code

You have three good options. Pick one.

#### Option A - Azure Functions Core Tools (recommended)

**Important:** Due to a known issue with solution files (`.slnx`) interfering with
the deployment package, use the clean publish folder method:

```bash
# macOS / Linux (zsh/bash)
cd /path/to/AzureFunctions-triggers-test
az login                                    # if not already signed in
az account set --subscription "<sub-id>"    # if you have multiple subscriptions

# Build and publish to a clean output folder
dotnet publish FunctionApp1.csproj --configuration Release --output ./publish

# Verify functions.metadata exists (critical for function discovery)
ls -l publish/functions.metadata

# Deploy from the publish folder
cd publish
func azure functionapp publish func-<base> --no-build --dotnet-isolated
cd ..
```

```powershell
# Windows (PowerShell)
cd C:\path\to\AzureFunctions-triggers-test
az login                                    # if not already signed in
az account set --subscription "<sub-id>"    # if you have multiple subscriptions

# Build and publish to a clean output folder
dotnet publish FunctionApp1.csproj --configuration Release --output ./publish

# Verify functions.metadata exists (critical for function discovery)
dir publish\functions.metadata

# Deploy from the publish folder
cd publish
func azure functionapp publish func-<base> --no-build --dotnet-isolated
cd ..
```

**Why this method:**
- `dotnet publish` on the `.csproj` ensures the `functions.metadata` file is
  correctly generated and included in the deployment package
- `--no-build` deploys exactly what's in the publish folder (no rebuild surprises)
- `--dotnet-isolated` specifies the .NET isolated worker runtime model

**Verify deployment succeeded:**
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

If you see an empty list, see the **Troubleshooting** section at the end of this document.

#### Option B - VS Code Azure Functions extension

1. Install the **Azure Functions** extension.
2. Sign in (`F1` → `Azure: Sign in`).
3. Right-click the `AzureFunctions-triggers-test` folder → **Deploy to Function App** →
   pick `func-<base>` → confirm overwrite.

#### Option C - GitHub Actions

Use the portal's **Deployment Center** → **GitHub** flow; it generates a
workflow file in your repo that builds and pushes on every commit. Skip if
you're just doing one-off deploys.

### 1.9 Verify the deployment

1. Function App → left nav: **Functions**. You should see:
   - `BlobIngestFunction`
   - `RowProcessorFunction`
   - `ArchiveFunction`
2. Tail the logs using one of:
   - **Log stream**: Function App → left nav: **Monitoring** → **Log stream**
     (works on Linux Consumption; shows the host runtime plus your `_logger`
     output in real time).
   - **Application Insights**: Function App → **Application Insights** →
     **Live metrics** (real-time) or **Logs** (KQL queries against the
     `traces` and `requests` tables). This is the recommended path on Linux
     because filesystem-based log files are not exposed there.
3. Trigger the pipeline by uploading the sample CSV:
   ```bash
   # macOS / Linux
   az storage blob upload \
     --account-name st<base> \
     --container-name incoming \
     --file sample-data/contacts.csv \
     --name contacts.csv \
     --auth-mode key
   ```
   ```powershell
   # Windows (PowerShell)
   az storage blob upload `
     --account-name st<base> `
     --container-name incoming `
     --file sample-data\contacts.csv `
     --name contacts.csv `
     --auth-mode key
   ```
4. Within ~10s the BlobIngest log should fire, then 5 RowProcessor invocations,
   then one Archive invocation. Confirm:
   - SQL: open the database → **Query editor (preview)** → sign in → run
     `SELECT * FROM dbo.FileIngestions; SELECT * FROM dbo.Contacts;`.
   - Archive blob: storage account → **Containers** → `archive` → you should
     see `contacts.csv` with 5 rows + header.

**Phase 1 complete.**

---

## Phase 2 - Migrate Storage and Service Bus to managed identity

Goal: remove the `StorageConnection` and `ServiceBusConnection` secrets and
let the Function App authenticate using its own identity for blob and queue
access too. (SQL is already on managed identity from step 1.5c, and the
Function App's identity was enabled in step 1.5b — so we go straight to the
RBAC role assignments.)

### 2.1 Grant the Function App access to the storage account

1. Storage account → left nav: **Access control (IAM)** → **+ Add** → **Add
   role assignment**.
2. Search for and pick each of these roles, one at a time, repeating the wizard:
   - **Storage Blob Data Contributor** - blob read/write for `incoming` and `archive`.
   - **Storage Queue Data Contributor** - the Functions host uses queues
     internally for AzureWebJobsStorage.
   - **Storage Table Data Contributor** - same reason (singleton leases).
   - **Storage Account Contributor** - lets the Functions host manage host
     locks. (Skip this only if you tightly control which features run.)
3. For each: **Next** → **Assign access to**: **Managed identity** →
   **+ Select members** → **Managed identity**: *Function App* → pick
   `func-<base>` → **Select** → **Review + assign**.

### 2.2 Grant the Function App access to Service Bus

1. Service Bus namespace → left nav: **Access control (IAM)** → **+ Add** →
   **Add role assignment**.
2. Add **both** of these roles, repeating the wizard:
   - **Azure Service Bus Data Sender** - Trigger 1 + Trigger 2 publish to queues.
   - **Azure Service Bus Data Receiver** - Triggers 2 + 3 read from queues.
3. Same flow as 2.1 — assign each to the Function App's managed identity.

> Alternatively assign **Azure Service Bus Data Owner** once (it's the union
> of Sender + Receiver + manage). Sender + Receiver is the least-privilege
> choice.

### 2.3 Switch the app settings to identity-based connections

The Azure Functions runtime resolves identity-based connections by looking
for **suffixed** app settings instead of one connection string. After this
step there should be **no** secrets in your settings for storage or Service
Bus.

1. Function App → **Settings** → **Environment variables** → **App settings**.
2. **Delete** these settings:
   - `StorageConnection`
   - `ServiceBusConnection`
   - `AzureWebJobsStorage`
3. **+ Add** the replacements:

   | Name                                   | Value                                                 |
   |----------------------------------------|-------------------------------------------------------|
   | `AzureWebJobsStorage__accountName`     | `st<base>`                                            |
   | `StorageConnection__blobServiceUri`    | `https://st<base>.blob.core.windows.net`              |
   | `StorageConnection__queueServiceUri`   | `https://st<base>.queue.core.windows.net`             |
   | `StorageConnection__tableServiceUri`   | `https://st<base>.table.core.windows.net`             |
   | `ServiceBusConnection__fullyQualifiedNamespace` | `sb-<base>.servicebus.windows.net`           |

4. **Apply** → **Confirm**. The app restarts.

> **Why the suffixes**: the Functions runtime looks for
> `<settingName>__<property>`. The presence of `*ServiceUri` /
> `*fullyQualifiedNamespace` (and the absence of a flat connection string)
> tells it to use **DefaultAzureCredential**, which resolves to the
> system-assigned managed identity on the Function App.

### 2.4 Update `Program.cs` for managed identity

The trigger and output bindings in the source already accept either auth
model without any change:

```@/Users/abdulsamad/DEV/Lumovy/AzureFunctions-triggers-test/Functions/BlobIngestFunction.cs:35-36
        [BlobTrigger("incoming/{name}", Connection = "StorageConnection")] Stream blobStream,
        string name,
```

```@/Users/abdulsamad/DEV/Lumovy/AzureFunctions-triggers-test/Functions/RowProcessorFunction.cs:39-41
    [Function(nameof(RowProcessorFunction))]
    [ServiceBusOutput("file-complete-queue", Connection = "ServiceBusConnection")]
    public async Task<string?> Run(
```

```@/Users/abdulsamad/DEV/Lumovy/AzureFunctions-triggers-test/Program.cs:17-26
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var conn = cfg.GetValue<string>("StorageConnection")
                ?? throw new InvalidOperationException("StorageConnection is not configured.");
            return new BlobServiceClient(conn);
        });
```

The only code that needs editing is the manual `BlobServiceClient`
registration in `Program.cs`. Its `BlobServiceClient(string)` overload only
accepts a connection string and will throw once the `StorageConnection`
app setting is gone. Replace the singleton with one that picks either the
connection string (for local dev) or the URI + `DefaultAzureCredential` (for
Azure with MI):

```csharp
services.AddSingleton(sp =>
{
    var cfg = sp.GetRequiredService<IConfiguration>();
    var conn = cfg.GetValue<string>("StorageConnection");
    if (!string.IsNullOrWhiteSpace(conn))
    {
        return new BlobServiceClient(conn);
    }

    var uri = cfg.GetValue<string>("StorageConnection__blobServiceUri")
        ?? throw new InvalidOperationException(
            "Either StorageConnection or StorageConnection__blobServiceUri must be set.");
    return new BlobServiceClient(new Uri(uri), new DefaultAzureCredential());
});
```

(Add `using Azure.Identity;` at the top of the file.) The same code path
supports both auth models; in this Azure-only project the identity branch
is the one that runs in production. Re-deploy after the edit.

### 2.5 Re-test

Re-run the upload from 1.8. The pipeline should behave identically; the
only difference is in the App Insights logs (no more `SharedAccessSignature`
strings, requests show `aad` auth).

---

## Retire the local dev stack

Now that everything runs against real Azure resources, the following
files/folders from the repo are no longer needed and can be deleted to
keep the project clean:

| Path                                      | Why it can go                                         |
|-------------------------------------------|-------------------------------------------------------|
| `docker-compose.yml`                      | Started Azurite + SQL Edge + Service Bus emulator.    |
| `servicebus-emulator/Config.json`         | Declared the local SB queues; Azure owns them now.    |
| *Docker sections of* `README.md`          | "Running locally" steps now live in this doc.         |

**Keep** these:

- `sample-data/contacts.csv` — still useful as the CSV you upload to the
  `incoming` container in step 1.8.
- `local.settings.json` — only if you want to point `func start` at real
  Azure endpoints for ad-hoc local debugging. Otherwise delete it too.

Once the files are gone, update the repo's `README.md` so "Running locally"
points at this runbook instead of Docker Compose.

---

## Cleanup

When you're done experimenting, delete the whole resource group to stop
billing. The same single-line command works in **bash, zsh, PowerShell and
cmd.exe** as long as you have `az` on your PATH:

```bash
az group delete --name rg-<base> --yes --no-wait
```

---

## Troubleshooting

### Functions show `0 functions found` after a successful deployment

**Root cause**: A `.slnx` or `.sln` solution file in the project directory
causes `func azure functionapp publish` to exclude `functions.metadata` from
the deployment package. Without that file the runtime cannot discover any
functions.

**Fix**: Always deploy from a clean publish folder:

```powershell
dotnet publish FunctionApp1.csproj --configuration Release --output ./publish
cd publish
func azure functionapp publish func-<base> --no-build --dotnet-isolated
cd ..
```

Verify immediately:
```powershell
func azure functionapp list-functions func-<base>
```

---

### `BlobIngestFunction` throws exceptions on every invocation, tables never created

Two separate issues typically combine to cause this:

**Issue A — `EnsureDatabaseAsync` cannot connect to `master`.**  
The managed identity is a contained user in `ContactsDb` only. When
`SqlRepository.EnsureDatabaseAsync` redirects the connection to `master`
it is rejected, and the resulting `SqlException` aborted the whole
`EnsureSchemaAsync` call — so `CREATE TABLE` never ran. The code already
handles this gracefully (the exception is caught and logged as a warning).
If you see this warning in logs it is expected and harmless.

**Issue B — `ALTER ROLE` statements were not applied.**  
If you ran all four SQL lines (`CREATE USER` + three `ALTER ROLE`) as one
batch and `CREATE USER` failed (user already exists), the Portal aborted the
batch and the roles were never granted. Run just the three `ALTER ROLE`
statements on their own:

```sql
ALTER ROLE db_datareader ADD MEMBER [func-<base>];
ALTER ROLE db_datawriter ADD MEMBER [func-<base>];
ALTER ROLE db_ddladmin   ADD MEMBER [func-<base>];
```

After granting roles, upload a **new filename** to `incoming`. Blobs that
already failed five delivery attempts are moved to the
`webjobs-blobtrigger-poison` queue and will never be retried.

---

### Blob trigger sees the file but skips it

```
Blob 'x.csv' will be skipped ... because this blob with ETag '...' has already been processed.
```

The runtime writes a blob receipt the first time it attempts to process a
blob. If the function crashed on that attempt the receipt still exists, so
the file is permanently skipped. **Upload the same content under a different
filename** to trigger a fresh invocation.

---

### `az storage blob upload --auth-mode login` returns permission denied

Your user account does not have the *Storage Blob Data Contributor* RBAC role
on the storage account. Use `--auth-mode key` for one-off uploads instead:

```powershell
az storage blob upload --account-name st<base> --container-name incoming \
  --file sample-data/contacts.csv --name test.csv --auth-mode key
```

---

## Quick checklist

- [ ] Resource group `rg-<base>` in **North Europe** (or your fallback Free-offer region)
- [ ] Storage account `st<base>` with `incoming` + `archive` containers
- [ ] Azure SQL server `sql-<base>` + database `ContactsDb` (Free offer, Entra-only auth)
- [ ] Yourself set as Microsoft Entra admin on the SQL server
- [ ] Service Bus namespace `sb-<base>` (Standard) with `contacts-queue` + `file-complete-queue`
- [ ] App Insights `appi-<base>` + Log Analytics workspace `log-<base>`
- [ ] Function App `func-<base>` (Consumption, Linux, .NET 8 isolated)
- [ ] System-assigned managed identity enabled on the Function App (step 1.5b)
- [ ] T-SQL `CREATE USER [func-<base>] FROM EXTERNAL PROVIDER` + role grants run in Query editor (step 1.5c)
- [ ] App settings: `StorageConnection`, `ServiceBusConnection`, `SqlConnectionString` (with `Authentication=Active Directory Default`)
- [ ] Code deployed via `func azure functionapp publish`
- [ ] Sample CSV upload → SQL rows + archive blob both present
- [ ] (Phase 2) RBAC roles assigned on storage + Service Bus
- [ ] (Phase 2) App settings switched to `__blobServiceUri` / `__fullyQualifiedNamespace` form, `StorageConnection` + `ServiceBusConnection` settings removed
- [ ] (Phase 2) `Program.cs` updated to use `DefaultAzureCredential` when no connection string is set
- [ ] (Phase 2) Re-deployed and re-tested
