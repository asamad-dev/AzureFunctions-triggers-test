using CsvHelper.Configuration.Attributes;

namespace FunctionApp1.Models;

/// <summary>
/// Represents a single row of the contacts CSV.
/// Used for:
///   1. CSV parsing (via CsvHelper, header names match the CSV).
///   2. Service Bus message payload (JSON serialized) between Trigger 1 and Trigger 2.
///   3. Mapping to/from the Contacts SQL table.
/// </summary>
public class ContactRecord
{
    [Name("FirstName")]
    public string FirstName { get; set; } = string.Empty;

    [Name("LastName")]
    public string LastName { get; set; } = string.Empty;

    [Name("Email")]
    public string Email { get; set; } = string.Empty;

    [Name("PhoneNumber")]
    public string PhoneNumber { get; set; } = string.Empty;

    // Fields below are NOT part of the CSV but travel with the Service Bus message so Trigger 2 can persist context and know when the file is done.
    [Ignore]
    public string FileName { get; set; } = string.Empty;

    [Ignore]
    public int RowIndex { get; set; }

    [Ignore]
    public int TotalRows { get; set; }
}
