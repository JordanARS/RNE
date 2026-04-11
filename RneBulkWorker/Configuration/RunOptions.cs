namespace RneBulkWorker.Configuration;

public sealed class RunOptions
{
    public bool RunOnce { get; set; } = true;
    public int IntervalMinutes { get; set; } = 1440;
    public string OutputRoot { get; set; } = ".\\runs";
    public bool TreatPresenceAsExcluded { get; set; } = true;
}
