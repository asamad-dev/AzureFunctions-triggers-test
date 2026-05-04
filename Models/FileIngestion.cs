namespace FunctionApp1.Models;

/// <summary>
/// Tracks ingestion progress for a single uploaded CSV file.
/// Stored in the FileIngestions SQL table.
/// </summary>
public class FileIngestion
{
    public long Id { get; set; }
    public string FileName { get; set; } = string.Empty;
    public int RowCount { get; set; }
    public int ProcessedRows { get; set; }
    public string Status { get; set; } = "Pending"; // Pending | Completed
    public DateTime CreatedAt { get; set; }
    public DateTime? CompletedAt { get; set; }
}
