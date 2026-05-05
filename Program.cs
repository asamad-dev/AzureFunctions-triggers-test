using Azure.Storage.Blobs;
using FunctionApp1.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices((context, services) =>
    {
        services.AddSingleton<SqlRepository>();
        services.AddSingleton<CsvService>();

        // BlobServiceClient for the Archive function. Uses the same
        // "StorageConnection" setting as the BlobTrigger so local dev against
        // Azurite and production against a real storage account both work.
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var conn = cfg.GetValue<string>("StorageConnection")
                ?? throw new InvalidOperationException("StorageConnection is not configured.");
            return new BlobServiceClient(conn);
        });
    })
    .Build();

host.Run();
