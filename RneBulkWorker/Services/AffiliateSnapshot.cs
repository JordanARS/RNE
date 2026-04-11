namespace RneBulkWorker.Services;

public sealed record AffiliateSnapshot(
    IReadOnlyCollection<string> Emails,
    IReadOnlyCollection<string> Phones,
    IReadOnlyCollection<BusinessPartnerContact> Partners
);
