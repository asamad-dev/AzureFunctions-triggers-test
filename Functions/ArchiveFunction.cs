using System.Text.Json;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Specialized;
using FunctionApp1.Models;
using FunctionApp1.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace FunctionApp1.Functions;

/// <summary>
/// Trigger 3 — Service Bus Queue Trigger on "file-complete-queue".
/// Reads the full set of contacts for the completed file from SQL, then
/// writes (or appends) them to the "archive" blob container under the same
/// filename as the source. Uses an Append Blob so repeated ticks for the
/// same filename cleanly append rather than overwriting.
/// </summary>
public class ArchiveFunction
{
    // Destination blob container for archived CSVs.
    private const string ArchiveContainer = "archive";

    // Injected via DI in Program.cs.
    private readonly SqlRepository _sql;
    private readonly CsvService _csv;
    private readonly BlobServiceClient _blobs;
    private readonly ILogger<ArchiveFunction> _logger;

    public ArchiveFunction(
        SqlRepository sql,
        CsvService csv,
        BlobServiceClient blobs,
        ILogger<ArchiveFunction> logger)
    {
        _sql = sql;
        _csv = csv;
        _blobs = blobs;
        _logger = logger;
    }

    // [ServiceBusTrigger] -> input: completion tick from "file-complete-queue".
    // No output binding here; the side effect is a blob write.
    [Function(nameof(ArchiveFunction))]
    public async Task Run(
        [ServiceBusTrigger("file-complete-queue", Connection = "ServiceBusConnection")] string messageBody,
        CancellationToken ct)
    {
        await _sql.EnsureSchemaAsync(ct);

        // Deserialize the tick emitted by Trigger 2.
        var tick = JsonSerializer.Deserialize<RowProcessorFunction.CompletionTick>(messageBody)
            ?? throw new InvalidOperationException("Received empty/invalid completion tick.");

        _logger.LogInformation(
            "Archive: tick received for {FileName} ({RowCount} rows)",
            tick.FileName, tick.RowCount);

        // Pull every row for this file, ordered by RowIndex, from SQL.
        var contacts = new List<ContactRecord>();
        await foreach (var c in _sql.GetContactsByFileNameAsync(tick.FileName, ct))
        {
            contacts.Add(c);
        }

        if (contacts.Count == 0)
        {
            _logger.LogWarning("Archive: no contacts found in SQL for {FileName}, nothing to archive.", tick.FileName);
            return;
        }

        // Ensure the archive container exists, then grab an Append Blob client
        // for the target file. Append Blobs let us safely tack on more rows if
        // a retry ever delivers the same tick twice.
        var container = _blobs.GetBlobContainerClient(ArchiveContainer);
        await container.CreateIfNotExistsAsync(cancellationToken: ct);

        var appendBlob = container.GetAppendBlobClient(tick.FileName);

        // Build the CSV payload: include the header only when this is a brand
        // new archive file; otherwise append rows alone so the header isn't
        // repeated mid-file.
        byte[] payload;
        if (!await appendBlob.ExistsAsync(ct))
        {
            await appendBlob.CreateAsync(cancellationToken: ct);
            payload = _csv.WriteContactsWithHeader(contacts);
            _logger.LogInformation("Archive: creating {FileName} in archive container.", tick.FileName);
        }
        else
        {
            payload = _csv.WriteContactsWithoutHeader(contacts);
            _logger.LogInformation("Archive: appending to existing {FileName} in archive container.", tick.FileName);
        }

        // Azure Append Blobs cap each block at 4 MB - chunk larger payloads.
        const int maxBlock = 4 * 1024 * 1024;
        for (var offset = 0; offset < payload.Length; offset += maxBlock)
        {
            var len = Math.Min(maxBlock, payload.Length - offset);
            using var chunk = new MemoryStream(payload, offset, len);
            await appendBlob.AppendBlockAsync(chunk, cancellationToken: ct);
        }

        _logger.LogInformation(
            "Archive: wrote {Bytes} bytes ({Rows} rows) for {FileName}.",
            payload.Length, contacts.Count, tick.FileName);
    }
}
