using System.IO.Compression;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using Microsoft.Extensions.Options;
using RneBulkWorker.Configuration;

namespace RneBulkWorker.Services;

public sealed class RneApiClient
{
    private readonly HttpClient _httpClient;
    private readonly RneOptions _options;

    public RneApiClient(HttpClient httpClient, IOptions<RneOptions> options)
    {
        _httpClient = httpClient;
        _options = options.Value;
    }

    public async Task<string> UploadZipAsync(string zipPath, string type, CancellationToken cancellationToken)
    {
        using var fileStream = File.OpenRead(zipPath);
        using var form = new MultipartFormDataContent();
        using var fileContent = new StreamContent(fileStream);

        fileContent.Headers.ContentType = new MediaTypeHeaderValue("application/zip");
        form.Add(fileContent, "file", Path.GetFileName(zipPath));
        form.Add(new StringContent(type), "type");

        using var req = new HttpRequestMessage(HttpMethod.Post, _options.UploadPath)
        {
            Content = form
        };

        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _options.Token);

        using var resp = await _httpClient.SendAsync(req, cancellationToken);
        var body = await resp.Content.ReadAsStringAsync(cancellationToken);

        if (!resp.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"Error HTTP {(int)resp.StatusCode} en carga RNE: {body}");
        }

        using var doc = JsonDocument.Parse(body);
        if (doc.RootElement.TryGetProperty("data", out var dataProp) && dataProp.ValueKind == JsonValueKind.String)
        {
            var guid = dataProp.GetString();
            if (!string.IsNullOrWhiteSpace(guid))
            {
                return guid;
            }
        }

        throw new InvalidOperationException($"No se pudo obtener GUID desde respuesta de carga: {body}");
    }

    public async Task<string> PollAndDownloadAsync(string guid, string outputZipPath, CancellationToken cancellationToken)
    {
        var path = _options.DownloadPathTemplate.Replace("{guid}", guid, StringComparison.OrdinalIgnoreCase);

        for (var i = 1; i <= _options.MaxAttempts; i++)
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, path);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _options.Token);

            using var resp = await _httpClient.SendAsync(req, cancellationToken);

            if (resp.IsSuccessStatusCode)
            {
                await using var fs = File.Create(outputZipPath);
                await resp.Content.CopyToAsync(fs, cancellationToken);
                return outputZipPath;
            }

            var body = await resp.Content.ReadAsStringAsync(cancellationToken);
            if (resp.StatusCode == HttpStatusCode.Conflict)
            {
                await Task.Delay(TimeSpan.FromSeconds(_options.PollSeconds), cancellationToken);
                continue;
            }

            throw new InvalidOperationException($"Error HTTP {(int)resp.StatusCode} consultando estado RNE: {body}");
        }

        throw new TimeoutException($"No fue posible descargar el resultado para GUID {guid} en {_options.MaxAttempts} intentos.");
    }

    public static void ExtractZip(string zipPath, string targetDirectory)
    {
        if (Directory.Exists(targetDirectory))
        {
            Directory.Delete(targetDirectory, recursive: true);
        }

        Directory.CreateDirectory(targetDirectory);
        ZipFile.ExtractToDirectory(zipPath, targetDirectory);
    }
}
