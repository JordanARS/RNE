namespace RneBulkWorker.Services;

public sealed record BusinessPartnerContact(
    string CardCode,
    string CardName,
    string? Email,
    IReadOnlyCollection<string> Phones
);
