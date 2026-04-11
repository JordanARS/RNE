namespace RneBulkWorker.Configuration;

public sealed class SourceOptions
{
    public string Mode { get; set; } = "Csv";
    public bool UseCsvSource { get; set; } = true;
    public string CsvPath { get; set; } = ".\\sap_afiliados.csv";
    public string CardCodeColumnName { get; set; } = "CardCode";
    public string CardNameColumnName { get; set; } = "CardName";
    public string EmailColumnName { get; set; } = "E_Mail";
    public string PhoneColumnName { get; set; } = "Cellular";
    public string SqlConnectionString { get; set; } = string.Empty;
    public string SqlQuery { get; set; } = "SELECT CardCode, CardName, E_Mail AS Email, Cellular AS Phone FROM OCRD WHERE frozenFor = 'N'";
}
