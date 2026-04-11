namespace RneBulkWorker.Configuration;

public sealed class SapServiceLayerOptions
{
    public bool Enabled { get; set; } = false;
    public string BaseUrl { get; set; } = "https://181.79.11.178:50000/b1s/v1";
    public string CompanyDb { get; set; } = "SERFUNLLANOS_TEST";
    public string UserName { get; set; } = string.Empty;
    public string Password { get; set; } = string.Empty;
    public string BusinessPartnersQuery { get; set; } = "/BusinessPartners?$select=CardCode,CardName,Phone1,Phone2,Cellular,EmailAddress&$filter=startswith(CardCode,'C')&$top=100000";
    public bool AllowInvalidCertificate { get; set; } = true;
}
