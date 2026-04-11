using RneBulkWorker;
using RneBulkWorker.Configuration;
using RneBulkWorker.Services;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.Configure<RneOptions>(builder.Configuration.GetSection("Rne"));
builder.Services.Configure<RunOptions>(builder.Configuration.GetSection("Run"));
builder.Services.Configure<SourceOptions>(builder.Configuration.GetSection("Source"));
builder.Services.Configure<SapServiceLayerOptions>(builder.Configuration.GetSection("SapServiceLayer"));

builder.Services.AddSingleton<AffiliateProvider>();
builder.Services.AddHttpClient<RneApiClient>((sp, client) =>
{
	var rneOptions = sp.GetRequiredService<Microsoft.Extensions.Options.IOptions<RneOptions>>().Value;
	client.BaseAddress = new Uri(rneOptions.BaseUrl);
	client.Timeout = TimeSpan.FromSeconds(rneOptions.HttpTimeoutSeconds);
});

builder.Services.AddHttpClient<SapServiceLayerClient>((sp, client) =>
{
	var sapOptions = sp.GetRequiredService<Microsoft.Extensions.Options.IOptions<SapServiceLayerOptions>>().Value;
	client.BaseAddress = new Uri(sapOptions.BaseUrl);
	client.Timeout = TimeSpan.FromSeconds(180);
})
.ConfigurePrimaryHttpMessageHandler(sp =>
{
	var sapOptions = sp.GetRequiredService<Microsoft.Extensions.Options.IOptions<SapServiceLayerOptions>>().Value;
	return new HttpClientHandler
	{
		ServerCertificateCustomValidationCallback = sapOptions.AllowInvalidCertificate
			? HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
			: null
	};
});

builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
