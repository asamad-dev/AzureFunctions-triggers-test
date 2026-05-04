using System.Text.Json;
using FunctionApp1.Models;
using FunctionApp1.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace FunctionApp1.Functions;

/// <summary>
/// Trigger 1 — Blob Trigger.
/// Fires when a CSV is uploaded to the "incoming" blob container. Parses the file, records a tracking row in FileIngestions, and fans out one Service Bus message per CSV row to the "contacts-queue".
///
/// If a FileIngestion row with the same (FileName, RowCount) already exists we skip processing entirely.
/// </summary>
public class BlobIngestFunction
{
    // Injected via DI in Program.cs.
    private readonly SqlRepository _sql;
    private readonly CsvService _csv;
    private readonly ILogger<BlobIngestFunction> _logger;

    public BlobIngestFunction(SqlRepository sql, CsvService csv, ILogger<BlobIngestFunction> logger)
    {
        _sql = sql;
        _csv = csv;
        _logger = logger;
    }

    // [BlobTrigger]    -> input: any blob written to the "incoming" container.
    // [ServiceBusOutput] -> any strings returned are sent as messages to "contacts-queue".
    [Function(nameof(BlobIngestFunction))]
    [ServiceBusOutput("contacts-queue", Connection = "ServiceBusConnection")]
    public async Task<string[]> Run(
        [BlobTrigger("incoming/{name}", Connection = "StorageConnection")] Stream blobStream,
        string name,
        CancellationToken ct)
    {
        _logger.LogInformation("BlobIngest: received blob {FileName}", name);

        // Lazy one-time DB + table bootstrap (no-op after first call).
        await _sql.EnsureSchemaAsync(ct);

        // Buffer into memory so CsvHelper gets a seekable stream and so we can
        // count rows before enqueuing. CSVs here are small-to-medium; if huge
        // files become a concern we can switch to a streaming pass.
        await using var ms = new MemoryStream();
        await blobStream.CopyToAsync(ms, ct);
        ms.Position = 0;

        var rows = _csv.ReadContacts(ms);
        var rowCount = rows.Count;

        if (rowCount == 0)
        {
            _logger.LogWarning("BlobIngest: {FileName} had 0 data rows, nothing to enqueue.", name);
            return Array.Empty<string>();
        }

        // Spec option (c): if (FileName, RowCount) already exists, skip entirely.
        if (await _sql.IngestionExistsAsync(name, rowCount, ct))
        {
            _logger.LogInformation(
                "BlobIngest: ingestion for ({FileName}, rows={RowCount}) already exists, skipping.",
                name, rowCount);
            return Array.Empty<string>();
        }

        var ingestionId = await _sql.CreateIngestionAsync(name, rowCount, ct);
        _logger.LogInformation(
            "BlobIngest: created ingestion {IngestionId} for {FileName} with {RowCount} rows.",
            ingestionId, name, rowCount);

        // Fan out: one Service Bus message per CSV row. We attach FileName,
        // RowIndex and TotalRows so Trigger 2 can persist the row and know
        // when the file is fully processed.
        var messages = new string[rowCount];
        for (var i = 0; i < rowCount; i++)
        {
            var r = rows[i];
            r.FileName = name;
            r.RowIndex = i;
            r.TotalRows = rowCount;
            messages[i] = JsonSerializer.Serialize(r);
        }

        _logger.LogInformation(
            "BlobIngest: enqueuing {Count} messages to contacts-queue for {FileName}.",
            messages.Length, name);
        return messages;
    }
}
