using System.Text.Json;
using FunctionApp1.Models;
using FunctionApp1.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace FunctionApp1.Functions;

/// <summary>
/// Trigger 2 — Service Bus Queue Trigger on "contacts-queue".
/// Persists a single contact row into the Contacts table and atomically
/// increments FileIngestions.ProcessedRows. When the last row of a file has
/// been processed (ProcessedRows == RowCount), the ingestion is marked
/// Completed and a tick message is emitted to "file-complete-queue" so
/// Trigger 3 can archive the file.
/// </summary>
public class RowProcessorFunction
{
    // Injected via DI in Program.cs.
    private readonly SqlRepository _sql;
    private readonly ILogger<RowProcessorFunction> _logger;

    public RowProcessorFunction(SqlRepository sql, ILogger<RowProcessorFunction> logger)
    {
        _sql = sql;
        _logger = logger;
    }

    public record CompletionTick(string FileName, int RowCount);

    // [ServiceBusTrigger] -> input: one row message from "contacts-queue".
    // [ServiceBusOutput]  -> returning a string emits that tick to "file-complete-queue"; returning null emits nothing.
    [Function(nameof(RowProcessorFunction))]
    [ServiceBusOutput("file-complete-queue", Connection = "ServiceBusConnection")]
    public async Task<string?> Run(
        [ServiceBusTrigger("contacts-queue", Connection = "ServiceBusConnection")] string messageBody,
        CancellationToken ct)
    {
        await _sql.EnsureSchemaAsync(ct);

        // Deserialize the ContactRecord Trigger 1 serialized into the message body.
        var record = JsonSerializer.Deserialize<ContactRecord>(messageBody)
            ?? throw new InvalidOperationException("Received empty/invalid contact message.");

        _logger.LogInformation(
            "RowProcessor: {FileName} row {RowIndex}/{TotalRows} ({Email})",
            record.FileName, record.RowIndex, record.TotalRows, record.Email);

        // Single atomic SQL statement: inserts the contact row AND bumps
        // ProcessedRows only if the insert actually happened. Safe against
        // duplicate Service Bus deliveries.
        var newProcessed = await _sql.InsertContactAndIncrementAsync(record, ct);

        // Last row of the file -> mark Completed and emit the tick so Trigger 3 archives.
        if (newProcessed >= record.TotalRows)
        {
            await _sql.MarkIngestionCompletedAsync(record.FileName, ct);
            _logger.LogInformation(
                "RowProcessor: {FileName} completed ({Processed}/{Total}), emitting tick.",
                record.FileName, newProcessed, record.TotalRows);

            return JsonSerializer.Serialize(new CompletionTick(record.FileName, record.TotalRows));
        }

        // Not the last row yet - no downstream message.
        return null;
    }
}
