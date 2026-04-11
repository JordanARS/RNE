using System.Data;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using RneBulkWorker.Configuration;

namespace RneBulkWorker.Services;

public sealed class AffiliateProvider
{
    private static readonly Regex EmailRegex = new("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", RegexOptions.Compiled);
    private readonly SourceOptions _options;
    private readonly SapServiceLayerClient _sapServiceLayerClient;

    public AffiliateProvider(IOptions<SourceOptions> options, SapServiceLayerClient sapServiceLayerClient)
    {
        _options = options.Value;
        _sapServiceLayerClient = sapServiceLayerClient;
    }

    public async Task<AffiliateSnapshot> GetAsync(CancellationToken cancellationToken)
    {
        var mode = (_options.Mode ?? string.Empty).Trim();
        if (mode.Equals("SapApi", StringComparison.OrdinalIgnoreCase))
        {
            return await GetFromSapApiAsync(cancellationToken);
        }

        if (mode.Equals("Sql", StringComparison.OrdinalIgnoreCase))
        {
            return await GetFromSqlAsync(cancellationToken);
        }

        if (mode.Equals("Csv", StringComparison.OrdinalIgnoreCase))
        {
            return await GetFromCsvAsync(cancellationToken);
        }

        return _options.UseCsvSource
            ? await GetFromCsvAsync(cancellationToken)
            : await GetFromSqlAsync(cancellationToken);
    }

    private async Task<AffiliateSnapshot> GetFromSapApiAsync(CancellationToken cancellationToken)
    {
        var partners = await _sapServiceLayerClient.GetBusinessPartnersAsync(cancellationToken);
        return BuildSnapshotFromPartners(partners);
    }

    private async Task<AffiliateSnapshot> GetFromCsvAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(_options.CsvPath))
        {
            throw new FileNotFoundException("No existe el CSV de entrada configurado en Source:CsvPath", _options.CsvPath);
        }

        var lines = await File.ReadAllLinesAsync(_options.CsvPath, cancellationToken);
        if (lines.Length == 0)
        {
            return new AffiliateSnapshot(Array.Empty<string>(), Array.Empty<string>(), Array.Empty<BusinessPartnerContact>());
        }

        var header = lines[0].Split(',');
        var cardCodeIndex = Array.FindIndex(header, h => string.Equals(h.Trim(), _options.CardCodeColumnName, StringComparison.OrdinalIgnoreCase));
        var cardNameIndex = Array.FindIndex(header, h => string.Equals(h.Trim(), _options.CardNameColumnName, StringComparison.OrdinalIgnoreCase));
        var emailIndex = Array.FindIndex(header, h => string.Equals(h.Trim(), _options.EmailColumnName, StringComparison.OrdinalIgnoreCase));
        var phoneIndex = Array.FindIndex(header, h => string.Equals(h.Trim(), _options.PhoneColumnName, StringComparison.OrdinalIgnoreCase));

        var partners = new List<BusinessPartnerContact>();

        for (var i = 1; i < lines.Length; i++)
        {
            var line = lines[i];
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            var parts = line.Split(',');
            var cardCode = cardCodeIndex >= 0 && cardCodeIndex < parts.Length ? parts[cardCodeIndex].Trim() : string.Empty;
            var cardName = cardNameIndex >= 0 && cardNameIndex < parts.Length ? parts[cardNameIndex].Trim() : string.Empty;
            var email = emailIndex >= 0 && emailIndex < parts.Length ? NormalizeEmail(parts[emailIndex]) : null;
            var phones = new List<string>();
            if (phoneIndex >= 0 && phoneIndex < parts.Length)
            {
                var phone = NormalizePhone(parts[phoneIndex]);
                if (phone is not null)
                {
                    phones.Add(phone);
                }
            }

            partners.Add(new BusinessPartnerContact(cardCode, cardName, email, phones));
        }

        return BuildSnapshotFromPartners(partners);
    }

    private async Task<AffiliateSnapshot> GetFromSqlAsync(CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(_options.SqlConnectionString))
        {
            throw new InvalidOperationException("Configurar Source:SqlConnectionString para usar SQL.");
        }

        var partners = new List<BusinessPartnerContact>();

        await using var conn = new SqlConnection(_options.SqlConnectionString);
        await conn.OpenAsync(cancellationToken);

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = _options.SqlQuery;
        cmd.CommandType = CommandType.Text;

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var cardCode = ReadDb(reader, "CardCode") ?? string.Empty;
            var cardName = ReadDb(reader, "CardName") ?? string.Empty;
            var email = NormalizeEmail(ReadDb(reader, "Email"));
            var phone = NormalizePhone(ReadDb(reader, "Phone"));
            var phones = phone is null ? Array.Empty<string>() : new[] { phone };
            partners.Add(new BusinessPartnerContact(cardCode, cardName, email, phones));
        }

        return BuildSnapshotFromPartners(partners);
    }

    private static AffiliateSnapshot BuildSnapshotFromPartners(IReadOnlyCollection<BusinessPartnerContact> partners)
    {
        var emails = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var phones = new HashSet<string>(StringComparer.Ordinal);

        foreach (var partner in partners)
        {
            if (!string.IsNullOrWhiteSpace(partner.Email))
            {
                emails.Add(partner.Email);
            }

            foreach (var phone in partner.Phones)
            {
                if (!string.IsNullOrWhiteSpace(phone))
                {
                    phones.Add(phone);
                }
            }
        }

        return new AffiliateSnapshot(emails.ToArray(), phones.ToArray(), partners);
    }

    private static string? ReadDb(SqlDataReader reader, string column)
    {
        try
        {
            var idx = reader.GetOrdinal(column);
            if (reader.IsDBNull(idx))
            {
                return null;
            }

            return reader.GetValue(idx)?.ToString();
        }
        catch (IndexOutOfRangeException)
        {
            return null;
        }
    }

    private static string? NormalizeEmail(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var normalized = value.Trim().ToLowerInvariant();
        return EmailRegex.IsMatch(normalized) ? normalized : null;
    }

    private static string? NormalizePhone(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var digits = new string(value.Where(char.IsDigit).ToArray());
        return digits.Length >= 7 ? digits : null;
    }
}
