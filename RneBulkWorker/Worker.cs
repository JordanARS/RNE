using System.IO.Compression;
using System.Text;
using Microsoft.Extensions.Options;
using RneBulkWorker.Configuration;
using RneBulkWorker.Services;

namespace RneBulkWorker;

public sealed class Worker : BackgroundService
{
    private readonly ILogger<Worker> _logger;
    private readonly AffiliateProvider _affiliateProvider;
    private readonly RneApiClient _rneApiClient;
    private readonly RunOptions _runOptions;

    public Worker(
        ILogger<Worker> logger,
        AffiliateProvider affiliateProvider,
        RneApiClient rneApiClient,
        IOptions<RunOptions> runOptions)
    {
        _logger = logger;
        _affiliateProvider = affiliateProvider;
        _rneApiClient = rneApiClient;
        _runOptions = runOptions.Value;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        do
        {
            await RunCycleAsync(stoppingToken);

            if (_runOptions.RunOnce)
            {
                break;
            }

            var delay = TimeSpan.FromMinutes(_runOptions.IntervalMinutes);
            _logger.LogInformation("Ciclo completado. Esperando {Delay} para siguiente ejecucion.", delay);
            await Task.Delay(delay, stoppingToken);
        }
        while (!stoppingToken.IsCancellationRequested);
    }

    private async Task RunCycleAsync(CancellationToken cancellationToken)
    {
        var start = DateTimeOffset.Now;
        var runId = start.ToString("yyyyMMdd_HHmmss");
        var runDir = Path.Combine(_runOptions.OutputRoot, runId);
        Directory.CreateDirectory(runDir);

        _logger.LogInformation("Iniciando ciclo RNE {RunId} en {RunDir}", runId, runDir);

        var snapshot = await _affiliateProvider.GetAsync(cancellationToken);
        _logger.LogInformation("Datos origen: {EmailCount} correos, {PhoneCount} telefonos", snapshot.Emails.Count, snapshot.Phones.Count);

        var corExcluded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var telExcluded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        if (snapshot.Emails.Count > 0)
        {
            corExcluded = await ProcessTypeAsync("COR", snapshot.Emails, runDir, cancellationToken);
        }

        if (snapshot.Phones.Count > 0)
        {
            telExcluded = await ProcessTypeAsync("TEL", snapshot.Phones, runDir, cancellationToken);
        }

        await WritePartnerRelationAsync(snapshot.Partners, corExcluded, telExcluded, runDir, cancellationToken);

        _logger.LogInformation("Ciclo RNE finalizado en {ElapsedSeconds} segundos", (DateTimeOffset.Now - start).TotalSeconds);
    }

    private async Task<HashSet<string>> ProcessTypeAsync(string type, IReadOnlyCollection<string> values, string runDir, CancellationToken cancellationToken)
    {
        var typeLower = type.ToLowerInvariant();
        var typeDir = Path.Combine(runDir, typeLower);
        Directory.CreateDirectory(typeDir);

        var inputCsv = Path.Combine(typeDir, $"input_{typeLower}.csv");
        await File.WriteAllLinesAsync(inputCsv, values, Encoding.UTF8, cancellationToken);

        var inputZip = Path.Combine(typeDir, $"input_{typeLower}.zip");
        BuildSingleFileZip(inputCsv, inputZip);

        _logger.LogInformation("Enviando lote {Type} con {Count} registros", type, values.Count);
        var guid = await _rneApiClient.UploadZipAsync(inputZip, type, cancellationToken);
        _logger.LogInformation("Lote {Type} cargado con GUID {Guid}", type, guid);

        var outputZip = Path.Combine(typeDir, $"resultado_{typeLower}.zip");
        await _rneApiClient.PollAndDownloadAsync(guid, outputZip, cancellationToken);

        var extractedDir = Path.Combine(typeDir, "resultado_extraido");
        RneApiClient.ExtractZip(outputZip, extractedDir);

        var excludedSet = ParseOutputValues(extractedDir);
        var auditCsv = Path.Combine(typeDir, $"auditoria_{typeLower}.csv");
        await WriteAuditAsync(values, excludedSet, auditCsv, cancellationToken);

        _logger.LogInformation("Lote {Type} finalizado. Registros en salida RNE: {ExcludedCount}", type, excludedSet.Count);
        return excludedSet;
    }

    private static void BuildSingleFileZip(string inputFilePath, string zipPath)
    {
        if (File.Exists(zipPath))
        {
            File.Delete(zipPath);
        }

        using var zipStream = File.Create(zipPath);
        using var archive = new ZipArchive(zipStream, ZipArchiveMode.Create);
        archive.CreateEntryFromFile(inputFilePath, Path.GetFileName(inputFilePath));
    }

    private static HashSet<string> ParseOutputValues(string extractedDir)
    {
        var output = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var csvFiles = Directory.GetFiles(extractedDir, "*.csv", SearchOption.AllDirectories);

        foreach (var file in csvFiles)
        {
            foreach (var line in File.ReadLines(file, Encoding.UTF8))
            {
                if (string.IsNullOrWhiteSpace(line))
                {
                    continue;
                }

                var first = line.Split(',')[0].Trim().Trim('"');
                if (!string.IsNullOrWhiteSpace(first))
                {
                    output.Add(first);
                }
            }
        }

        return output;
    }

    private async Task WriteAuditAsync(
        IReadOnlyCollection<string> allValues,
        HashSet<string> outputValues,
        string auditPath,
        CancellationToken cancellationToken)
    {
        var lines = new List<string>(allValues.Count + 1)
        {
            "value,in_output_rne,is_excluded,processed_at"
        };

        var now = DateTimeOffset.Now.ToString("O");
        foreach (var value in allValues)
        {
            var inOutput = outputValues.Contains(value);
            var isExcluded = _runOptions.TreatPresenceAsExcluded && inOutput;
            lines.Add($"{EscapeCsv(value)},{inOutput.ToString().ToLowerInvariant()},{isExcluded.ToString().ToLowerInvariant()},{now}");
        }

        await File.WriteAllLinesAsync(auditPath, lines, Encoding.UTF8, cancellationToken);
    }

    private async Task WritePartnerRelationAsync(
        IReadOnlyCollection<BusinessPartnerContact> partners,
        HashSet<string> emailInRne,
        HashSet<string> phoneInRne,
        string runDir,
        CancellationToken cancellationToken)
    {
        var path = Path.Combine(runDir, "relacion_socios_rne.csv");
        var lines = new List<string>(partners.Count + 1)
        {
            "card_code,card_name,email,email_in_rne,phones,phone_in_rne,processed_at"
        };

        var now = DateTimeOffset.Now.ToString("O");
        foreach (var partner in partners)
        {
            var email = partner.Email ?? string.Empty;
            var emailFlag = !string.IsNullOrWhiteSpace(email) && emailInRne.Contains(email);

            var phones = partner.Phones.Where(p => !string.IsNullOrWhiteSpace(p)).ToArray();
            var phoneFlag = phones.Any(phoneInRne.Contains);

            lines.Add(string.Join(",",
                EscapeCsv(partner.CardCode),
                EscapeCsv(partner.CardName),
                EscapeCsv(email),
                emailFlag.ToString().ToLowerInvariant(),
                EscapeCsv(string.Join("|", phones)),
                phoneFlag.ToString().ToLowerInvariant(),
                now));
        }

        await File.WriteAllLinesAsync(path, lines, Encoding.UTF8, cancellationToken);
        _logger.LogInformation("Archivo de relacion generado: {Path}", path);
    }

    private static string EscapeCsv(string value)
    {
        if (!value.Contains('"') && !value.Contains(',') && !value.Contains('\n') && !value.Contains('\r'))
        {
            return value;
        }

        return $"\"{value.Replace("\"", "\"\"")}\"";
    }
}
