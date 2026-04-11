using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using RneBulkWorker.Configuration;

namespace RneBulkWorker.Services;

public sealed class SapServiceLayerClient
{
    private readonly HttpClient _httpClient;
    private readonly SapServiceLayerOptions _options;

    public SapServiceLayerClient(HttpClient httpClient, IOptions<SapServiceLayerOptions> options)
    {
        _httpClient = httpClient;
        _options = options.Value;
    }

    public async Task<IReadOnlyCollection<BusinessPartnerContact>> GetBusinessPartnersAsync(CancellationToken cancellationToken)
    {
        var cookies = await LoginAsync(cancellationToken);

        using var req = new HttpRequestMessage(HttpMethod.Get, _options.BusinessPartnersQuery);
        req.Headers.Add("Cookie", cookies);

        using var resp = await _httpClient.SendAsync(req, cancellationToken);
        var body = await resp.Content.ReadAsStringAsync(cancellationToken);

        if (!resp.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"Error SAP BusinessPartners HTTP {(int)resp.StatusCode}: {body}");
        }

        using var doc = JsonDocument.Parse(body);
        if (!doc.RootElement.TryGetProperty("value", out var value) || value.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException("Respuesta de SAP sin arreglo 'value'.");
        }

        var result = new List<BusinessPartnerContact>();
        foreach (var item in value.EnumerateArray())
        {
            var cardCode = ReadString(item, "CardCode") ?? string.Empty;
            var cardName = ReadString(item, "CardName") ?? string.Empty;
            var email = ReadString(item, "EmailAddress");

            var phones = new HashSet<string>(StringComparer.Ordinal);
            AddIfValue(phones, ReadString(item, "Phone1"));
            AddIfValue(phones, ReadString(item, "Phone2"));
            AddIfValue(phones, ReadString(item, "Cellular"));

            result.Add(new BusinessPartnerContact(cardCode, cardName, email, phones.ToArray()));
        }

        return result;
    }

    private async Task<string> LoginAsync(CancellationToken cancellationToken)
    {
        var payload = JsonSerializer.Serialize(new
        {
            CompanyDB = _options.CompanyDb,
            UserName = _options.UserName,
            Password = _options.Password
        });

        using var req = new HttpRequestMessage(HttpMethod.Post, "/Login")
        {
            Content = new StringContent(payload, Encoding.UTF8, "application/json")
        };

        using var resp = await _httpClient.SendAsync(req, cancellationToken);
        var body = await resp.Content.ReadAsStringAsync(cancellationToken);

        if (!resp.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"Login SAP fallo HTTP {(int)resp.StatusCode}: {body}");
        }

        using var doc = JsonDocument.Parse(body);
        if (!doc.RootElement.TryGetProperty("SessionId", out var sessionProp))
        {
            throw new InvalidOperationException("Login SAP no devolvio SessionId.");
        }

        var sessionId = sessionProp.GetString();
        if (string.IsNullOrWhiteSpace(sessionId))
        {
            throw new InvalidOperationException("SessionId vacio en login SAP.");
        }

        var cookies = new List<string> { $"B1SESSION={sessionId}" };
        if (resp.Headers.TryGetValues("Set-Cookie", out var setCookies))
        {
            foreach (var cookie in setCookies)
            {
                if (cookie.StartsWith("ROUTEID=", StringComparison.OrdinalIgnoreCase))
                {
                    var route = cookie.Split(';', StringSplitOptions.RemoveEmptyEntries)[0];
                    cookies.Add(route);
                }
            }
        }

        return string.Join("; ", cookies);
    }

    private static string? ReadString(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var prop))
        {
            return null;
        }

        return prop.ValueKind switch
        {
            JsonValueKind.String => prop.GetString(),
            JsonValueKind.Null => null,
            _ => prop.ToString()
        };
    }

    private static void AddIfValue(HashSet<string> target, string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        target.Add(value.Trim());
    }
}
