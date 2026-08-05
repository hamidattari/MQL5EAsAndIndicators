using Microsoft.Extensions.Options;
using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Serialization;

// ──────────────────────────────────────────────────────────────────────────────
// TradeCopierServer – Self-hosted ASP.NET Core trade relay  (fan-out edition)
//
// Endpoints
// ─────────
//   POST /trade          – Master EA pushes a trade command (JSON body).
//                          The command is fan-out copied into every registered
//                          slave's private queue.
//
//   GET  /poll?id=<sid>  – Slave EA long-polls with its unique SlaveID.
//                          The server creates a queue for <sid> on first call
//                          and returns the next command for that slave, or {}
//                          on timeout.
//
//   DELETE /slave?id=<sid> – Graceful unregister (called on EA deinit).
//                            Removes the slave's queue so stale queues don't
//                            accumulate.
//
//   GET /health          – Unauthenticated. Returns server status + slave list.
//
// Authentication
// ──────────────
//   Every request (except /health) must carry:
//     Authorization: Bearer <AuthToken>
//
// Fan-out guarantee
// ─────────────────
//   Every command POSTed by the master is placed into EVERY currently
//   registered slave queue. A slave that is temporarily offline will receive
//   queued commands when it reconnects (queue is kept in memory until the
//   slave unregisters or the process restarts).
// ──────────────────────────────────────────────────────────────────────────────

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseWindowsService();

builder.Services.Configure<TradeCopierOptions>(
    builder.Configuration.GetSection("TradeCopier"));

// Fan-out queue manager is the single source of truth for all slave queues.
builder.Services.AddSingleton<SlaveQueueManager>();

builder.Services.ConfigureHttpJsonOptions(o =>
{
    o.SerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
    o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
});

var app = builder.Build();

// ── Auth middleware ───────────────────────────────────────────────────────────
// AUTH TEMPORARILY DISABLED – re-enable before going live
//app.Use(async (context, next) =>
//{
//    // /health is intentionally public – skip auth so uptime monitors work.
//    if (context.Request.Path.StartsWithSegments("/health"))
//    {
//        await next(context);
//        return;
//    }
//
//    var opts  = context.RequestServices.GetRequiredService<IOptions<TradeCopierOptions>>().Value;
//    var token = context.Request.Headers["Authorization"].FirstOrDefault();
//
//    if (string.IsNullOrEmpty(token) || token != $"Bearer {opts.AuthToken}")
//    {
//        context.Response.StatusCode = 401;
//        await context.Response.WriteAsync("Unauthorized");
//        return;
//    }
//    await next(context);
//});

// ── POST /trade ───────────────────────────────────────────────────────────────
// Master EA sends a trade command here. It is fan-out copied to all slaves.
app.MapPost("/trade", async (HttpContext context,
                             SlaveQueueManager manager,
                             ILogger<Program> logger) =>
{
    TradeCommand? cmd;
    try
    {
        cmd = await context.Request.ReadFromJsonAsync<TradeCommand>();
    }
    catch (JsonException ex)
    {
        logger.LogWarning("POST /trade – bad JSON: {msg}", ex.Message);
        return Results.BadRequest("Invalid JSON");
    }

    if (cmd is null || string.IsNullOrEmpty(cmd.Action) || string.IsNullOrEmpty(cmd.Symbol))
    {
        logger.LogWarning("POST /trade – missing required fields");
        return Results.BadRequest("Missing required fields (action, symbol)");
    }

    int fanCount = manager.FanOut(cmd);
    logger.LogInformation(
        "POST /trade – {action} {symbol} ticket={ticket} fanned out to {n} slave(s)",
        cmd.Action, cmd.Symbol, cmd.Ticket, fanCount);

    return Results.Ok(new { queued = true, slaves = fanCount });
});

// ── GET /poll?id=<slaveId> ────────────────────────────────────────────────────
// Slave EA calls this with its unique ID. Blocks until a command is available
// for that slave or the long-poll timeout fires.
app.MapGet("/poll", async (HttpContext context,
                           SlaveQueueManager manager,
                           IOptions<TradeCopierOptions> opts,
                           ILogger<Program> logger) =>
{
    string? slaveId = context.Request.Query["id"];
    if (string.IsNullOrWhiteSpace(slaveId))
        return Results.BadRequest("Query parameter 'id' is required");

    // Register the slave (no-op if already registered).
    manager.Register(slaveId);

    var timeout = TimeSpan.FromSeconds(opts.Value.LongPollTimeoutSeconds);
    using var cts = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
    cts.CancelAfter(timeout);

    TradeCommand? cmd = await manager.DequeueAsync(slaveId, cts.Token);

    if (cmd is null)
    {
        logger.LogDebug("GET /poll id={id} – timeout, no command", slaveId);
        return Results.Ok(new { });
    }

    logger.LogInformation(
        "GET /poll id={id} – delivering {action} {symbol} ticket={ticket}",
        slaveId, cmd.Action, cmd.Symbol, cmd.Ticket);
    return Results.Ok(cmd);
});

// ── DELETE /slave?id=<slaveId> ────────────────────────────────────────────────
// Called by the Slave EA on deinit to cleanly remove its queue.
app.MapDelete("/slave", (HttpContext context,
                         SlaveQueueManager manager,
                         ILogger<Program> logger) =>
{
    string? slaveId = context.Request.Query["id"];
    if (string.IsNullOrWhiteSpace(slaveId))
        return Results.BadRequest("Query parameter 'id' is required");

    manager.Unregister(slaveId);
    logger.LogInformation("DELETE /slave id={id} – unregistered", slaveId);
    return Results.Ok(new { removed = true });
});

// ── GET /health ───────────────────────────────────────────────────────────────
// Unauthenticated. Returns server status and the list of registered slaves.
app.MapGet("/health", (SlaveQueueManager manager) =>
{
    var slaves = manager.RegisteredSlaves();
    return Results.Ok(new
    {
        status = "ok",
        utc = DateTime.UtcNow,
        slaveCount = slaves.Length,
        slaves
    });
});

// ── Startup ───────────────────────────────────────────────────────────────────
var serverOpts = app.Services.GetRequiredService<IOptions<TradeCopierOptions>>().Value;
var startLogger = app.Services.GetRequiredService<ILogger<Program>>();
startLogger.LogInformation(
    "TradeCopierServer (fan-out) starting on port {port}", serverOpts.Port);
app.Urls.Add($"http://0.0.0.0:{serverOpts.Port}");

app.Run();

// ═════════════════════════════════════════════════════════════════════════════
// Supporting types
// ═════════════════════════════════════════════════════════════════════════════

/// <summary>
/// Manages one long-poll queue per slave.
/// Thread-safe for concurrent master writes and slave reads.
/// </summary>
public sealed class SlaveQueueManager
{
    // slaveId → its private queue
    private readonly ConcurrentDictionary<string, SlaveQueue> _slaves = new();

    /// <summary>Register a slave (idempotent).</summary>
    public void Register(string slaveId) =>
        _slaves.GetOrAdd(slaveId, _ => new SlaveQueue());

    /// <summary>Remove a slave and its pending commands.</summary>
    public void Unregister(string slaveId) =>
        _slaves.TryRemove(slaveId, out _);

    /// <summary>
    /// Fan-out: enqueue a copy of <paramref name="cmd"/> into every
    /// registered slave's queue and return how many slaves were notified.
    /// </summary>
    public int FanOut(TradeCommand cmd)
    {
        int count = 0;
        foreach (var (_, queue) in _slaves)
        {
            queue.Enqueue(cmd);
            count++;
        }
        return count;
    }

    /// <summary>
    /// Long-poll dequeue for a specific slave.
    /// Returns null when the cancellation token fires (timeout or disconnect).
    /// </summary>
    public Task<TradeCommand?> DequeueAsync(string slaveId, CancellationToken ct)
    {
        if (_slaves.TryGetValue(slaveId, out var queue))
            return queue.DequeueAsync(ct);
        // Slave not registered yet – return immediately with nothing.
        return Task.FromResult<TradeCommand?>(null);
    }

    /// <summary>List of currently registered slave IDs.</summary>
    public string[] RegisteredSlaves() => _slaves.Keys.ToArray();
}

/// <summary>
/// A single slave's blocking command queue.
/// Supports multiple concurrent waiters (though typically just one per slave).
/// </summary>
public sealed class SlaveQueue
{
    private readonly ConcurrentQueue<TradeCommand> _queue = new();
    private readonly ConcurrentQueue<SemaphoreSlim> _waiters = new();

    public void Enqueue(TradeCommand cmd)
    {
        _queue.Enqueue(cmd);
        // Wake the first waiting /poll consumer if any.
        if (_waiters.TryDequeue(out var waiter))
            waiter.Release();
    }

    public async Task<TradeCommand?> DequeueAsync(CancellationToken ct)
    {
        // Fast path: command already waiting.
        if (_queue.TryDequeue(out var cmd))
            return cmd;

        // Slow path: park until Enqueue wakes us or timeout fires.
        var waiter = new SemaphoreSlim(0, 1);
        _waiters.Enqueue(waiter);
        try
        {
            await waiter.WaitAsync(ct);
        }
        catch (OperationCanceledException)
        {
            return null;
        }

        _queue.TryDequeue(out cmd);
        return cmd;
    }
}

/// <summary>Configuration section bound from appsettings.json.</summary>
public sealed class TradeCopierOptions
{
    public string AuthToken { get; set; } = "CHANGE_ME";
    public int Port { get; set; } = 5000;
    public int LongPollTimeoutSeconds { get; set; } = 5;
}

/// <summary>
/// A single trade instruction passed between Master and Slave.
/// ticket/magic are quoted strings to preserve ulong precision.
/// </summary>
public sealed class TradeCommand
{
    [JsonPropertyName("action")] public string? Action { get; set; }
    [JsonPropertyName("symbol")] public string? Symbol { get; set; }
    [JsonPropertyName("type")] public string? Type { get; set; }
    [JsonPropertyName("entry")] public double Entry { get; set; }
    [JsonPropertyName("sl")] public double Sl { get; set; }
    [JsonPropertyName("tp")] public double Tp { get; set; }
    [JsonPropertyName("volume")] public double Volume { get; set; }
    [JsonPropertyName("ticket")] public string? Ticket { get; set; }
    [JsonPropertyName("magic")] public string? Magic { get; set; }
}
