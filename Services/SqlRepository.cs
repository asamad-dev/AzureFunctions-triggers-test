using FunctionApp1.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace FunctionApp1.Services;

/// <summary>
/// Data-access layer for the ContactsDb SQL database.
/// Owns DDL bootstrap and all read/write operations against the
/// FileIngestions and Contacts tables.
/// </summary>
public class SqlRepository
{
    private readonly string _connectionString;
    private readonly ILogger<SqlRepository> _logger;
    private bool _schemaInitialised;
    private readonly SemaphoreSlim _initLock = new(1, 1);

    public SqlRepository(IConfiguration configuration, ILogger<SqlRepository> logger)
    {
        _connectionString = configuration.GetValue<string>("SqlConnectionString")
            ?? throw new InvalidOperationException("SqlConnectionString is not configured.");
        _logger = logger;
    }

    /// <summary>
    /// Creates the database (if missing) and the required tables. Safe to call
    /// repeatedly; the first caller performs the work, subsequent calls are no-ops.
    /// </summary>
    public async Task EnsureSchemaAsync(CancellationToken ct = default)
    {
        if (_schemaInitialised) return;

        await _initLock.WaitAsync(ct);
        try
        {
            if (_schemaInitialised) return;

            await EnsureDatabaseAsync(ct);

            const string ddl = @"
IF OBJECT_ID('dbo.FileIngestions', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.FileIngestions (
        Id              BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        FileName        NVARCHAR(500) NOT NULL,
        [RowCount]      INT           NOT NULL,
        ProcessedRows   INT           NOT NULL CONSTRAINT DF_FileIngestions_ProcessedRows DEFAULT (0),
        Status          NVARCHAR(50)  NOT NULL CONSTRAINT DF_FileIngestions_Status DEFAULT ('Pending'),
        CreatedAt       DATETIME2(3)  NOT NULL CONSTRAINT DF_FileIngestions_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CompletedAt     DATETIME2(3)  NULL,
        CONSTRAINT UQ_FileIngestions_FileName_RowCount UNIQUE (FileName, [RowCount])
    );
END;

IF OBJECT_ID('dbo.Contacts', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Contacts (
        Id          BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        FileName    NVARCHAR(500) NOT NULL,
        RowIndex    INT           NOT NULL,
        FirstName   NVARCHAR(200) NOT NULL,
        LastName    NVARCHAR(200) NOT NULL,
        Email       NVARCHAR(320) NOT NULL,
        PhoneNumber NVARCHAR(50)  NOT NULL,
        CreatedAt   DATETIME2(3)  NOT NULL CONSTRAINT DF_Contacts_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT UQ_Contacts_FileName_RowIndex UNIQUE (FileName, RowIndex)
    );
END;";

            await using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(ddl, conn);
            await cmd.ExecuteNonQueryAsync(ct);

            _schemaInitialised = true;
            _logger.LogInformation("SQL schema ensured (FileIngestions, Contacts).");
        }
        finally
        {
            _initLock.Release();
        }
    }

    /// <summary>
    /// Connects to the "master" database on the same server and creates the
    /// target database if it doesn't already exist. This lets local dev work
    /// with a bare SQL Server / Azure SQL Edge container.
    /// </summary>
    private async Task EnsureDatabaseAsync(CancellationToken ct)
    {
        var builder = new SqlConnectionStringBuilder(_connectionString);
        var targetDb = builder.InitialCatalog;
        if (string.IsNullOrWhiteSpace(targetDb))
        {
            // Nothing to create - caller is relying on server default DB.
            return;
        }

        builder.InitialCatalog = "master";
        var masterConnString = builder.ConnectionString;

        await using var conn = new SqlConnection(masterConnString);
        await conn.OpenAsync(ct);

        // Database name is interpolated (not parameterisable in CREATE DATABASE)
        // but is constrained to the value we already loaded from config.
        var sql = $@"
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @DbName)
BEGIN
    DECLARE @stmt NVARCHAR(200) = N'CREATE DATABASE [' + @DbName + N']';
    EXEC sp_executesql @stmt;
END;";

        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@DbName", System.Data.SqlDbType.NVarChar, 128).Value = targetDb;
        await cmd.ExecuteNonQueryAsync(ct);

        _logger.LogInformation("SQL database {Database} ensured.", targetDb);
    }

    /// <summary>
    /// Skip the entire CSV if a FileIngestion row with the same (FileName, RowCount) pair already exists.
    /// </summary>
    public async Task<bool> IngestionExistsAsync(string fileName, int rowCount, CancellationToken ct = default)
    {
        const string sql = @"
SELECT CAST(CASE WHEN EXISTS (
    SELECT 1 FROM dbo.FileIngestions
    WHERE FileName = @FileName AND [RowCount] = @RowCount
) THEN 1 ELSE 0 END AS BIT);";

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@FileName", System.Data.SqlDbType.NVarChar, 500).Value = fileName;
        cmd.Parameters.Add("@RowCount", System.Data.SqlDbType.Int).Value = rowCount;
        var result = await cmd.ExecuteScalarAsync(ct);
        return result is bool b && b;
    }

    /// <summary>
    /// Inserts a new pending FileIngestion row and returns its generated Id.
    /// </summary>
    public async Task<long> CreateIngestionAsync(string fileName, int rowCount, CancellationToken ct = default)
    {
        const string sql = @"
INSERT INTO dbo.FileIngestions (FileName, [RowCount])
OUTPUT INSERTED.Id
VALUES (@FileName, @RowCount);";

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@FileName", System.Data.SqlDbType.NVarChar, 500).Value = fileName;
        cmd.Parameters.Add("@RowCount", System.Data.SqlDbType.Int).Value = rowCount;
        var id = (long)(await cmd.ExecuteScalarAsync(ct))!;
        return id;
    }

    /// <summary>
    /// Atomically inserts a contact row and increments FileIngestions.ProcessedRows only when a real insert occurred. Returns the (possibly unchanged) ProcessedRows value after the operation so the caller can decide whether to emit the completion tick. Safe against duplicate Service Bus deliveries.
    /// </summary>
    public async Task<int> InsertContactAndIncrementAsync(ContactRecord record, CancellationToken ct = default)
    {
        const string sql = @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;

INSERT INTO dbo.Contacts (FileName, RowIndex, FirstName, LastName, Email, PhoneNumber)
SELECT @FileName, @RowIndex, @FirstName, @LastName, @Email, @PhoneNumber
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Contacts WITH (UPDLOCK, HOLDLOCK)
    WHERE FileName = @FileName AND RowIndex = @RowIndex
);

DECLARE @Inserted INT = @@ROWCOUNT;
DECLARE @NewProcessed INT = 0;

IF @Inserted > 0
BEGIN
    UPDATE dbo.FileIngestions
    SET ProcessedRows = ProcessedRows + 1,
        @NewProcessed = ProcessedRows + 1
    WHERE FileName = @FileName AND Status = 'Pending';
END
ELSE
BEGIN
    SELECT @NewProcessed = ProcessedRows
    FROM dbo.FileIngestions
    WHERE FileName = @FileName;
END

COMMIT;

SELECT @NewProcessed;";

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@FileName", System.Data.SqlDbType.NVarChar, 500).Value = record.FileName;
        cmd.Parameters.Add("@RowIndex", System.Data.SqlDbType.Int).Value = record.RowIndex;
        cmd.Parameters.Add("@FirstName", System.Data.SqlDbType.NVarChar, 200).Value = record.FirstName;
        cmd.Parameters.Add("@LastName", System.Data.SqlDbType.NVarChar, 200).Value = record.LastName;
        cmd.Parameters.Add("@Email", System.Data.SqlDbType.NVarChar, 320).Value = record.Email;
        cmd.Parameters.Add("@PhoneNumber", System.Data.SqlDbType.NVarChar, 50).Value = record.PhoneNumber;
        var result = await cmd.ExecuteScalarAsync(ct);
        return result is int n ? n : 0;
    }

    /// <summary>
    /// Marks the ingestion as Completed. Idempotent: only transitions Pending -> Completed.
    /// </summary>
    public async Task MarkIngestionCompletedAsync(string fileName, CancellationToken ct = default)
    {
        const string sql = @"
UPDATE dbo.FileIngestions
SET Status = 'Completed', CompletedAt = SYSUTCDATETIME()
WHERE FileName = @FileName AND Status = 'Pending';";

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@FileName", System.Data.SqlDbType.NVarChar, 500).Value = fileName;
        await cmd.ExecuteNonQueryAsync(ct);
    }

    /// <summary>
    /// Streams all contacts for a given file, ordered by RowIndex, for archiving.
    /// </summary>
    public async IAsyncEnumerable<ContactRecord> GetContactsByFileNameAsync(
        string fileName,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
    {
        const string sql = @"
SELECT FileName, RowIndex, FirstName, LastName, Email, PhoneNumber
FROM dbo.Contacts
WHERE FileName = @FileName
ORDER BY RowIndex ASC;";

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@FileName", System.Data.SqlDbType.NVarChar, 500).Value = fileName;

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            yield return new ContactRecord
            {
                FileName = reader.GetString(0),
                RowIndex = reader.GetInt32(1),
                FirstName = reader.GetString(2),
                LastName = reader.GetString(3),
                Email = reader.GetString(4),
                PhoneNumber = reader.GetString(5),
            };
        }
    }
}
