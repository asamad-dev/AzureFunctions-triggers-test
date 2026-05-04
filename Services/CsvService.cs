using System.Globalization;
using CsvHelper;
using CsvHelper.Configuration;
using FunctionApp1.Models;

namespace FunctionApp1.Services;

/// <summary>
/// Thin wrapper around CsvHelper for parsing and writing contact CSVs.
/// The CSV schema is fixed: FirstName, LastName, Email, PhoneNumber (with header).
/// </summary>
public class CsvService
{
    private static readonly CsvConfiguration ReadConfig = new(CultureInfo.InvariantCulture)
    {
        HasHeaderRecord = true,
        TrimOptions = TrimOptions.Trim,
        MissingFieldFound = null, // tolerate optional trailing fields
        IgnoreBlankLines = true,
    };

    private static readonly CsvConfiguration WriteConfig = new(CultureInfo.InvariantCulture)
    {
        HasHeaderRecord = true,
    };

    /// <summary>
    /// Parses a CSV stream into a list of ContactRecord. The stream must be seekable
    /// or fully readable; callers typically pass a MemoryStream or the blob stream.
    /// </summary>
    public List<ContactRecord> ReadContacts(Stream csvStream)
    {
        using var reader = new StreamReader(csvStream, leaveOpen: true);
        using var csv = new CsvReader(reader, ReadConfig);
        return csv.GetRecords<ContactRecord>().ToList();
    }

    /// <summary>
    /// Serialises contact rows into CSV bytes including header.
    /// Used when creating a brand-new archive blob.
    /// </summary>
    public byte[] WriteContactsWithHeader(IEnumerable<ContactRecord> contacts)
    {
        using var ms = new MemoryStream();
        using (var writer = new StreamWriter(ms, leaveOpen: true))
        using (var csv = new CsvWriter(writer, WriteConfig))
        {
            csv.WriteHeader<ContactRecord>();
            csv.NextRecord();
            foreach (var c in contacts)
            {
                csv.WriteRecord(c);
                csv.NextRecord();
            }
        }
        return ms.ToArray();
    }

    /// <summary>
    /// Serialises contact rows into CSV bytes WITHOUT a header, used when appending
    /// to an existing archive blob.
    /// </summary>
    public byte[] WriteContactsWithoutHeader(IEnumerable<ContactRecord> contacts)
    {
        var noHeaderConfig = new CsvConfiguration(CultureInfo.InvariantCulture)
        {
            HasHeaderRecord = false,
        };

        using var ms = new MemoryStream();
        using (var writer = new StreamWriter(ms, leaveOpen: true))
        using (var csv = new CsvWriter(writer, noHeaderConfig))
        {
            foreach (var c in contacts)
            {
                csv.WriteRecord(c);
                csv.NextRecord();
            }
        }
        return ms.ToArray();
    }
}
