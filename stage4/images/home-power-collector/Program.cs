using System.Globalization;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Aiursoft.ClickhouseSdk;
using Aiursoft.ClickhouseSdk.Abstractions;
using ClickHouse.Client.Utility;

namespace HomePowerCollector;

public static class Program
{
    public static async Task<int> Main()
    {
        try
        {
            var settings = CollectorSettings.FromEnvironment();
            using var shutdown = new CancellationTokenSource();
            Console.CancelKeyPress += (_, eventArgs) =>
            {
                eventArgs.Cancel = true;
                shutdown.Cancel();
            };

            using var homeAssistant = new HomeAssistantClient(settings);
            ClickHousePowerStore? store = null;

            Console.WriteLine(
                "Home power collector started. Sampling every {0} seconds into {1}.{2}.",
                settings.SampleInterval.TotalSeconds,
                settings.ClickHouseDatabase,
                settings.SampleTable);

            try
            {
                while (!shutdown.IsCancellationRequested)
                {
                    var sampleStartedAt = DateTime.UtcNow;

                    try
                    {
                        store ??= await ClickHousePowerStore.CreateAsync(settings);
                        var readings = await homeAssistant.GetPowerReadingsAsync(shutdown.Token);
                        await store.WriteSampleAsync(sampleStartedAt, readings);

                        Console.WriteLine(
                            "{0:O}: stored {1} power readings ({2:0.##} W total).",
                            sampleStartedAt,
                            readings.Count,
                            readings.Sum(reading => reading.PowerWatts));
                    }
                    catch (OperationCanceledException) when (shutdown.IsCancellationRequested)
                    {
                        break;
                    }
                    catch (Exception exception)
                    {
                        Console.Error.WriteLine(
                            "{0:O}: sampling failed: {1}",
                            DateTime.UtcNow,
                            exception.Message);

                        if (store is not null)
                        {
                            await store.DisposeAsync();
                            store = null;
                        }
                    }

                    var nextSampleAt = sampleStartedAt + settings.SampleInterval;
                    var delay = nextSampleAt - DateTime.UtcNow;
                    if (delay > TimeSpan.Zero)
                    {
                        await Task.Delay(delay, shutdown.Token);
                    }
                }
            }
            catch (OperationCanceledException) when (shutdown.IsCancellationRequested)
            {
                // Normal service shutdown.
            }
            finally
            {
                if (store is not null)
                {
                    await store.DisposeAsync();
                }
            }

            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine("Collector startup failed: {0}", exception.Message);
            return 1;
        }
    }
}

public sealed record PowerReading(string EntityId, string FriendlyName, double PowerWatts);

public sealed class HomeAssistantClient : IDisposable
{
    private readonly HttpClient _client;
    private readonly HashSet<string> _excludedEntities;

    public HomeAssistantClient(CollectorSettings settings)
    {
        _excludedEntities = settings.ExcludedPowerEntityIds;
        _client = new HttpClient
        {
            BaseAddress = new Uri(settings.HomeAssistantUrl),
            Timeout = TimeSpan.FromSeconds(10)
        };
        _client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", settings.HomeAssistantToken);
    }

    public async Task<IReadOnlyList<PowerReading>> GetPowerReadingsAsync(
        CancellationToken cancellationToken)
    {
        using var response = await _client.GetAsync("/api/states", cancellationToken);
        response.EnsureSuccessStatusCode();

        await using var responseStream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var states = await JsonDocument.ParseAsync(
            responseStream,
            cancellationToken: cancellationToken);

        var readings = new List<PowerReading>();
        foreach (var state in states.RootElement.EnumerateArray())
        {
            var entityId = GetOptionalString(state, "entity_id");
            if (entityId is null
                || !entityId.StartsWith("sensor.", StringComparison.Ordinal)
                || _excludedEntities.Contains(entityId)
                || !state.TryGetProperty("attributes", out var attributes))
            {
                continue;
            }

            var unit = GetOptionalString(attributes, "unit_of_measurement");
            if (unit is not ("W" or "kW"))
            {
                continue;
            }

            var stateText = GetOptionalString(state, "state");
            if (!double.TryParse(
                    stateText,
                    NumberStyles.Float,
                    CultureInfo.InvariantCulture,
                    out var power)
                || !double.IsFinite(power)
                || power < 0)
            {
                continue;
            }

            if (unit == "kW")
            {
                power *= 1000;
            }

            readings.Add(new PowerReading(
                entityId,
                GetOptionalString(attributes, "friendly_name") ?? entityId,
                power));
        }

        return readings;
    }

    public void Dispose()
    {
        _client.Dispose();
    }

    private static string? GetOptionalString(JsonElement element, string propertyName)
    {
        return element.TryGetProperty(propertyName, out var property)
               && property.ValueKind == JsonValueKind.String
            ? property.GetString()
            : null;
    }
}

public sealed class ClickHousePowerStore : IAsyncDisposable
{
    private readonly CollectorSettings _settings;
    private readonly PowerDbContext _context;
    private readonly HashSet<string> _knownColumns;
    private readonly Dictionary<string, string> _catalogNames;

    private ClickHousePowerStore(
        CollectorSettings settings,
        PowerDbContext context,
        HashSet<string> knownColumns,
        Dictionary<string, string> catalogNames)
    {
        _settings = settings;
        _context = context;
        _knownColumns = knownColumns;
        _catalogNames = catalogNames;
    }

    public static async Task<ClickHousePowerStore> CreateAsync(CollectorSettings settings)
    {
        var database = ClickhouseIdentifier.Quote(settings.ClickHouseDatabase);
        var sampleTable = ClickhouseIdentifier.Quote(settings.SampleTable);
        var catalogTable = ClickhouseIdentifier.Quote(settings.CatalogTable);

        await using (var initContext = new PowerDbContext(settings.BuildClickHouseConnectionString("default")))
        {
            await initContext.ExecuteAsync($"CREATE DATABASE IF NOT EXISTS {database}");
        }

        var context = new PowerDbContext(
            settings.BuildClickHouseConnectionString(settings.ClickHouseDatabase));

        try
        {
            await context.ExecuteAsync(
                $"""
                 CREATE TABLE IF NOT EXISTS {sampleTable}
                 (
                     `SampledAt` DateTime64(3, 'UTC'),
                     `TotalPowerWatts` Float64,
                     `EstimatedCurrentAmps` Float64
                 )
                 ENGINE = MergeTree()
                 ORDER BY `SampledAt`
                 """);

            await context.ExecuteAsync(
                $"""
                 CREATE TABLE IF NOT EXISTS {catalogTable}
                 (
                     `ColumnName` String,
                     `EntityId` String,
                     `FriendlyName` String,
                     `LastSeenAt` DateTime64(3, 'UTC')
                 )
                 ENGINE = ReplacingMergeTree(`LastSeenAt`)
                 ORDER BY `ColumnName`
                 """);

            var knownColumns = (await context.QueryAsync(
                    """
                    SELECT name
                    FROM system.columns
                    WHERE database = {database:String}
                      AND table = {table:String}
                    """,
                    reader => reader.GetString(0),
                    new Dictionary<string, object?>
                    {
                        ["database"] = settings.ClickHouseDatabase,
                        ["table"] = settings.SampleTable
                    }))
                .ToHashSet(StringComparer.Ordinal);

            var catalogNames = (await context.QueryAsync(
                    $"""
                     SELECT `ColumnName`, argMax(`FriendlyName`, `LastSeenAt`)
                     FROM {catalogTable}
                     GROUP BY `ColumnName`
                     """,
                    reader => new KeyValuePair<string, string>(
                        reader.GetString(0),
                        reader.GetString(1))))
                .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);

            return new ClickHousePowerStore(settings, context, knownColumns, catalogNames);
        }
        catch
        {
            await context.DisposeAsync();
            throw;
        }
    }

    public async Task WriteSampleAsync(
        DateTime sampledAt,
        IReadOnlyList<PowerReading> readings)
    {
        var columnsToAdd = readings
            .Select(reading => ToColumnName(reading.EntityId))
            .Where(column => !_knownColumns.Contains(column))
            .Distinct(StringComparer.Ordinal)
            .ToList();

        var quotedTable = ClickhouseIdentifier.Quote(_settings.SampleTable);
        foreach (var column in columnsToAdd)
        {
            await _context.ExecuteAsync(
                $"ALTER TABLE {quotedTable} ADD COLUMN IF NOT EXISTS "
                + $"{ClickhouseIdentifier.Quote(column)} Nullable(Float64)");
            _knownColumns.Add(column);
        }

        await UpdateCatalogAsync(sampledAt, readings);

        var readingsByColumn = readings
            .GroupBy(reading => ToColumnName(reading.EntityId), StringComparer.Ordinal)
            .ToDictionary(
                group => group.Key,
                group => group.Sum(reading => reading.PowerWatts),
                StringComparer.Ordinal);

        var totalPower = readingsByColumn.Values.Sum();
        var columnNames = new List<string>
        {
            ClickhouseIdentifier.Quote("SampledAt"),
            ClickhouseIdentifier.Quote("TotalPowerWatts"),
            ClickhouseIdentifier.Quote("EstimatedCurrentAmps")
        };
        var valueExpressions = new List<string>
        {
            "{sampledAt:DateTime64(3)}",
            "{totalPower:Float64}",
            "{estimatedCurrent:Float64}"
        };
        var parameters = new Dictionary<string, object?>
        {
            ["sampledAt"] = sampledAt,
            ["totalPower"] = totalPower,
            ["estimatedCurrent"] = totalPower / _settings.NominalVoltage
        };

        var parameterIndex = 0;
        foreach (var reading in readingsByColumn.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            var parameterName = $"power{parameterIndex}";
            columnNames.Add(ClickhouseIdentifier.Quote(reading.Key));
            valueExpressions.Add($"{{{parameterName}:Float64}}");
            parameters[parameterName] = reading.Value;
            parameterIndex++;
        }

        await _context.ExecuteAsync(
            $"INSERT INTO {quotedTable} ({string.Join(", ", columnNames)}) "
            + $"VALUES ({string.Join(", ", valueExpressions)})",
            parameters);
    }

    private async Task UpdateCatalogAsync(
        DateTime sampledAt,
        IReadOnlyList<PowerReading> readings)
    {
        var changedReadings = readings
            .Select(reading => new
            {
                Reading = reading,
                ColumnName = ToColumnName(reading.EntityId)
            })
            .Where(item => !_catalogNames.TryGetValue(item.ColumnName, out var knownName)
                           || knownName != item.Reading.FriendlyName)
            .GroupBy(item => item.ColumnName, StringComparer.Ordinal)
            .Select(group => group.First())
            .ToList();

        if (changedReadings.Count == 0)
        {
            return;
        }

        var values = new List<string>();
        var parameters = new Dictionary<string, object?>();
        for (var index = 0; index < changedReadings.Count; index++)
        {
            var item = changedReadings[index];
            values.Add(
                $"({{column{index}:String}}, {{entity{index}:String}}, "
                + $"{{name{index}:String}}, {{seen{index}:DateTime64(3)}})");
            parameters[$"column{index}"] = item.ColumnName;
            parameters[$"entity{index}"] = item.Reading.EntityId;
            parameters[$"name{index}"] = item.Reading.FriendlyName;
            parameters[$"seen{index}"] = sampledAt;
        }

        await _context.ExecuteAsync(
            $"INSERT INTO {ClickhouseIdentifier.Quote(_settings.CatalogTable)} "
            + "(`ColumnName`, `EntityId`, `FriendlyName`, `LastSeenAt`) VALUES "
            + string.Join(", ", values),
            parameters);

        foreach (var item in changedReadings)
        {
            _catalogNames[item.ColumnName] = item.Reading.FriendlyName;
        }
    }

    private static string ToColumnName(string entityId)
    {
        var normalized = Regex.Replace(entityId, "[^A-Za-z0-9_]", "_");
        if (normalized.Length > 100)
        {
            normalized = normalized[..100];
        }

        var hash = Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(entityId)))
            .ToLowerInvariant()[..8];
        return $"power_{normalized}_{hash}";
    }

    public ValueTask DisposeAsync()
    {
        return _context.DisposeAsync();
    }
}

public sealed class PowerDbContext : ClickhouseDbContext
{
    public PowerDbContext(string connectionString)
        : base(new ClickhouseOptions
        {
            ConnectionString = connectionString,
            Enabled = true,
            RetentionDays = 0
        })
    {
    }

    public async Task ExecuteAsync(
        string sql,
        IReadOnlyDictionary<string, object?>? parameters = null)
    {
        var connection = await GetConnection();
        await using var command = connection.CreateCommand();
        command.CommandText = sql;

        if (parameters is not null)
        {
            foreach (var parameter in parameters)
            {
                command.AddParameter(parameter.Key, parameter.Value ?? DBNull.Value);
            }
        }

        await command.ExecuteNonQueryAsync();
    }

    public override Task SaveChangesAsync()
    {
        return Task.CompletedTask;
    }
}

public sealed record CollectorSettings(
    string HomeAssistantUrl,
    string HomeAssistantToken,
    string ClickHouseHost,
    int ClickHousePort,
    string ClickHouseProtocol,
    string ClickHouseUser,
    string ClickHousePassword,
    string ClickHouseDatabase,
    string SampleTable,
    string CatalogTable,
    double NominalVoltage,
    TimeSpan SampleInterval,
    HashSet<string> ExcludedPowerEntityIds)
{
    public static CollectorSettings FromEnvironment()
    {
        var sampleIntervalSeconds = ReadPositiveInt("SAMPLE_INTERVAL_SECONDS", 15);
        var nominalVoltage = ReadPositiveDouble("NOMINAL_VOLTAGE", 220);

        return new CollectorSettings(
            RequireEnvironment("HOME_ASSISTANT_URL"),
            RequireEnvironment("HOME_ASSISTANT_TOKEN"),
            RequireEnvironment("CLICKHOUSE_HOST"),
            ReadPositiveInt("CLICKHOUSE_PORT", 8123),
            Environment.GetEnvironmentVariable("CLICKHOUSE_PROTOCOL") ?? "http",
            Environment.GetEnvironmentVariable("CLICKHOUSE_USER") ?? "default",
            RequireEnvironment("CLICKHOUSE_PASSWORD"),
            Environment.GetEnvironmentVariable("CLICKHOUSE_DATABASE") ?? "home_assistant",
            Environment.GetEnvironmentVariable("CLICKHOUSE_SAMPLE_TABLE") ?? "power_samples",
            Environment.GetEnvironmentVariable("CLICKHOUSE_CATALOG_TABLE") ?? "power_device_catalog",
            nominalVoltage,
            TimeSpan.FromSeconds(sampleIntervalSeconds),
            (Environment.GetEnvironmentVariable("EXCLUDED_POWER_ENTITY_IDS")
             ?? "sensor.iot_padw2p_4ab5_electric_power")
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .ToHashSet(StringComparer.Ordinal));
    }

    public string BuildClickHouseConnectionString(string database)
    {
        return string.Join(
            ';',
            $"Host={QuoteConnectionStringValue(ClickHouseHost)}",
            $"Protocol={QuoteConnectionStringValue(ClickHouseProtocol)}",
            $"Port={ClickHousePort}",
            $"Database={QuoteConnectionStringValue(database)}",
            $"User={QuoteConnectionStringValue(ClickHouseUser)}",
            $"Password={QuoteConnectionStringValue(ClickHousePassword)}");
    }

    private static string RequireEnvironment(string name)
    {
        return Environment.GetEnvironmentVariable(name)
               ?? throw new InvalidOperationException($"Required environment variable '{name}' is missing.");
    }

    private static int ReadPositiveInt(string name, int defaultValue)
    {
        var value = Environment.GetEnvironmentVariable(name);
        if (string.IsNullOrWhiteSpace(value))
        {
            return defaultValue;
        }

        return int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed)
               && parsed > 0
            ? parsed
            : throw new InvalidOperationException($"'{name}' must be a positive integer.");
    }

    private static double ReadPositiveDouble(string name, double defaultValue)
    {
        var value = Environment.GetEnvironmentVariable(name);
        if (string.IsNullOrWhiteSpace(value))
        {
            return defaultValue;
        }

        return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
               && double.IsFinite(parsed)
               && parsed > 0
            ? parsed
            : throw new InvalidOperationException($"'{name}' must be a positive number.");
    }

    private static string QuoteConnectionStringValue(string value)
    {
        return $"\"{value.Replace("\"", "\"\"")}\"";
    }
}
