namespace RneBulkWorker.Configuration;

public sealed class RneOptions
{
    public string BaseUrl { get; set; } = "https://tramitescrcom.gov.co";
    public string UploadPath { get; set; } = "/excluidosback/archivo/cargar";
    public string DownloadPathTemplate { get; set; } = "/excluidosback/archivo/descargar/{guid}";
    public string Token { get; set; } = string.Empty;
    public int PollSeconds { get; set; } = 15;
    public int MaxAttempts { get; set; } = 120;
    public int HttpTimeoutSeconds { get; set; } = 120;
}
