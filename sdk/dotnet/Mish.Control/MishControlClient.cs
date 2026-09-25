using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Mish.Control;

public enum RotateResult
{
    Changed,
    Unchanged,
    Failed,
    Rejected,
    Unknown,
}

public enum RotateReason
{
    None,
    Unauthorized,
    MethodNotAllowed,
    InvalidRequest,
    DeviceOffline,
    Busy,
    ProductFailed,
    ProductRejected,
    Timeout,
    InternalError,
}

public sealed class RotateIpRequest
{
    private RotateIpRequest()
    {
    }

    public static RotateIpRequest Instance { get; } = new();
}

public sealed record RotateIpTiming(
    long StartedAtMs,
    long CompletedAtMs,
    long DurationMs);

public sealed record RotateIpResponse(
    string? RequestId,
    bool Terminal,
    RotateResult Result,
    RotateReason Reason,
    long? OperationId,
    bool? Changed,
    bool? DeviceOnline,
    bool? Dispatched,
    bool Retryable,
    RotateIpTiming Timing);

public abstract class MishControlException : Exception
{
    protected MishControlException(string message, Exception? innerException = null)
        : base(message, innerException)
    {
    }
}

public sealed class MishControlTransportException : MishControlException
{
    public MishControlTransportException(
        string message,
        bool operationOutcomeMayBeUnknown,
        Exception? innerException = null)
        : base(message, innerException)
    {
        OperationOutcomeMayBeUnknown = operationOutcomeMayBeUnknown;
    }

    public bool OperationOutcomeMayBeUnknown { get; }
}

public sealed class MishControlProtocolException : MishControlException
{
    public MishControlProtocolException(
        string message,
        HttpStatusCode? statusCode = null,
        Exception? innerException = null)
        : base(message, innerException)
    {
        StatusCode = statusCode;
    }

    public HttpStatusCode? StatusCode { get; }
}

public sealed class MishControlClient : IDisposable
{
    public const string RotateSchema = "mish.control.rotate/v1";

    private const string RotateEndpoint = "https://api.alegria.by/v1/rotate";
    private const int MaxResponseBytes = 64 * 1024;
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(20);
    private static readonly Uri Endpoint = new(RotateEndpoint, UriKind.Absolute);
    private static readonly Regex RequestIdPattern =
        new("^mgr_[0-9a-f]{32}$", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private readonly HttpClient _httpClient;
    private readonly string _managerToken;

    public MishControlClient(string managerToken)
        : this(CreateDefaultHandler(), managerToken)
    {
    }

    internal MishControlClient(HttpMessageHandler handler, string managerToken)
    {
        ArgumentNullException.ThrowIfNull(handler);
        _managerToken = ValidateToken(managerToken);
        _httpClient = new HttpClient(handler, disposeHandler: true)
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }

    public async Task<RotateIpResponse> RotateIpAsync(
        CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint)
        {
            Content = new ByteArrayContent(Array.Empty<byte>()),
            Version = HttpVersion.Version11,
            VersionPolicy = HttpVersionPolicy.RequestVersionExact,
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _managerToken);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(RequestTimeout);

        HttpResponseMessage response;
        try
        {
            response = await _httpClient
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException exception)
        {
            throw new MishControlTransportException(
                "Remote rotation transport was cancelled or timed out; never replay automatically because the command may have been dispatched.",
                operationOutcomeMayBeUnknown: true,
                exception);
        }
        catch (HttpRequestException exception)
        {
            throw new MishControlTransportException(
                "Remote rotation transport failed; never replay automatically because the command may have been dispatched.",
                operationOutcomeMayBeUnknown: true,
                exception);
        }

        using (response)
        {
            var mediaType = response.Content.Headers.ContentType?.MediaType;
            if (!string.Equals(mediaType, "application/json", StringComparison.OrdinalIgnoreCase))
            {
                throw Protocol(
                    "response content type is not application/json.",
                    response.StatusCode);
            }

            byte[] body;
            try
            {
                body = await ReadBoundedResponseAsync(
                    response.Content,
                    MaxResponseBytes,
                    deadline.Token).ConfigureAwait(false);
            }
            catch (MishControlProtocolException)
            {
                throw;
            }
            catch (OperationCanceledException exception)
            {
                throw new MishControlTransportException(
                    "Remote rotation response body timed out; never replay automatically because the command may have been dispatched.",
                    operationOutcomeMayBeUnknown: true,
                    exception);
            }
            catch (HttpRequestException exception)
            {
                throw new MishControlTransportException(
                    "Remote rotation response body transport failed; never replay automatically because the command may have been dispatched.",
                    operationOutcomeMayBeUnknown: true,
                    exception);
            }
            catch (IOException exception)
            {
                throw new MishControlTransportException(
                    "Remote rotation response body transport failed; never replay automatically because the command may have been dispatched.",
                    operationOutcomeMayBeUnknown: true,
                    exception);
            }

            return ParseAndValidate(body, response.StatusCode);
        }
    }

    public void Dispose() => _httpClient.Dispose();

    private static SocketsHttpHandler CreateDefaultHandler() =>
        new()
        {
            AllowAutoRedirect = false,
            UseCookies = false,
        };

    private static async Task<byte[]> ReadBoundedResponseAsync(
        HttpContent content,
        int maxResponseBytes,
        CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is long declared &&
            declared > maxResponseBytes)
        {
            throw new MishControlProtocolException(
                "Remote rotation response exceeds the configured size bound.");
        }

        await using var stream = await content
            .ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var buffer = new MemoryStream(capacity: Math.Min(maxResponseBytes, 4096));
        var chunk = new byte[4096];
        var total = 0;

        while (true)
        {
            var read = await stream
                .ReadAsync(chunk.AsMemory(0, chunk.Length), cancellationToken)
                .ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            total += read;
            if (total > maxResponseBytes)
            {
                throw new MishControlProtocolException(
                    "Remote rotation response exceeds the configured size bound.");
            }

            buffer.Write(chunk, 0, read);
        }

        return buffer.ToArray();
    }

    private static RotateIpResponse ParseAndValidate(
        byte[] body,
        HttpStatusCode statusCode)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(body);
        }
        catch (JsonException exception)
        {
            throw new MishControlProtocolException(
                "Remote rotation response is not valid JSON.",
                statusCode,
                exception);
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw Protocol("response root is not an object.", statusCode);
            }

            var schema = GetRequiredString(root, "schema", statusCode);
            if (!string.Equals(schema, RotateSchema, StringComparison.Ordinal))
            {
                throw Protocol($"unsupported schema '{schema}'.", statusCode);
            }

            var requestId = GetNullableString(root, "request_id", statusCode);
            if (requestId is not null && !RequestIdPattern.IsMatch(requestId))
            {
                throw Protocol("request_id has an invalid v1 shape.", statusCode);
            }

            var terminal = GetRequiredBoolean(root, "terminal", statusCode);
            var result = ParseResult(
                GetRequiredString(root, "result", statusCode),
                statusCode);
            var reason = ParseReason(
                GetRequiredString(root, "reason", statusCode),
                statusCode);
            var operationId = GetNullablePositiveInt64(
                root,
                "operation_id",
                statusCode);
            var changed = GetNullableBoolean(root, "changed", statusCode);
            var deviceOnline = GetNullableBoolean(
                root,
                "device_online",
                statusCode);
            var dispatched = GetNullableBoolean(root, "dispatched", statusCode);
            var retryable = GetRequiredBoolean(root, "retryable", statusCode);

            var timing = GetRequiredObject(root, "timing", statusCode);
            var startedAtMs = GetRequiredNonNegativeInt64(
                timing,
                "started_at_ms",
                statusCode);
            var completedAtMs = GetRequiredNonNegativeInt64(
                timing,
                "completed_at_ms",
                statusCode);
            var durationMs = GetRequiredNonNegativeInt64(
                timing,
                "duration_ms",
                statusCode);

            if (completedAtMs < startedAtMs ||
                completedAtMs - startedAtMs != durationMs)
            {
                throw Protocol("timing is inconsistent.", statusCode);
            }

            ValidateSemanticContract(
                statusCode,
                requestId,
                terminal,
                result,
                reason,
                operationId,
                changed,
                deviceOnline,
                dispatched,
                retryable);

            return new RotateIpResponse(
                requestId,
                terminal,
                result,
                reason,
                operationId,
                changed,
                deviceOnline,
                dispatched,
                retryable,
                new RotateIpTiming(startedAtMs, completedAtMs, durationMs));
        }
    }

    private static void ValidateSemanticContract(
        HttpStatusCode statusCode,
        string? requestId,
        bool terminal,
        RotateResult result,
        RotateReason reason,
        long? operationId,
        bool? changed,
        bool? deviceOnline,
        bool? dispatched,
        bool retryable)
    {
        Require(
            terminal == (result != RotateResult.Unknown),
            "terminal does not match result semantics.",
            statusCode);

        var expectedChanged = result switch
        {
            RotateResult.Changed => true,
            RotateResult.Unchanged => false,
            _ => (bool?)null,
        };
        Require(
            changed == expectedChanged,
            "changed does not match result semantics.",
            statusCode);

        var expectedRetryable = dispatched == false &&
            (reason == RotateReason.DeviceOffline ||
             reason == RotateReason.Busy);
        Require(
            retryable == expectedRetryable,
            "retryable does not match dispatch/reason semantics.",
            statusCode);

        var reasonMatchesResult = reason switch
        {
            RotateReason.None =>
                result is RotateResult.Changed or RotateResult.Unchanged,
            RotateReason.ProductFailed =>
                result == RotateResult.Failed,
            RotateReason.ProductRejected =>
                result == RotateResult.Rejected,
            RotateReason.Unauthorized or
            RotateReason.MethodNotAllowed or
            RotateReason.InvalidRequest or
            RotateReason.DeviceOffline or
            RotateReason.Busy =>
                result == RotateResult.Rejected,
            RotateReason.Timeout or RotateReason.InternalError =>
                result == RotateResult.Unknown,
            _ => false,
        };
        Require(
            reasonMatchesResult,
            "reason does not match result semantics.",
            statusCode);

        switch (reason)
        {
            case RotateReason.Unauthorized:
            case RotateReason.MethodNotAllowed:
            case RotateReason.InvalidRequest:
                Require(
                    requestId is null,
                    "pre-correlation rejection unexpectedly has request_id.",
                    statusCode);
                Require(
                    dispatched == false,
                    "pre-correlation rejection must have dispatched=false.",
                    statusCode);
                Require(
                    operationId is null,
                    "pre-correlation rejection unexpectedly has operation_id.",
                    statusCode);
                break;

            case RotateReason.DeviceOffline:
                Require(
                    requestId is not null,
                    "DEVICE_OFFLINE is missing request_id.",
                    statusCode);
                Require(
                    dispatched == false,
                    "DEVICE_OFFLINE must have dispatched=false.",
                    statusCode);
                Require(
                    operationId is null,
                    "DEVICE_OFFLINE unexpectedly has operation_id.",
                    statusCode);
                Require(
                    deviceOnline == false,
                    "DEVICE_OFFLINE must have device_online=false.",
                    statusCode);
                break;

            case RotateReason.Busy:
                Require(
                    requestId is not null,
                    "BUSY is missing request_id.",
                    statusCode);
                Require(
                    dispatched == false,
                    "BUSY must have dispatched=false.",
                    statusCode);
                Require(
                    operationId is null,
                    "BUSY unexpectedly has operation_id.",
                    statusCode);
                break;

            case RotateReason.InternalError:
                Require(
                    requestId is not null,
                    "INTERNAL_ERROR is missing request_id.",
                    statusCode);
                Require(
                    dispatched is null,
                    "INTERNAL_ERROR must have dispatched=null.",
                    statusCode);
                Require(
                    deviceOnline is null,
                    "INTERNAL_ERROR must have device_online=null.",
                    statusCode);
                break;

            case RotateReason.Timeout:
                Require(
                    requestId is not null,
                    "TIMEOUT is missing request_id.",
                    statusCode);
                Require(
                    dispatched == true,
                    "TIMEOUT must have dispatched=true.",
                    statusCode);
                break;

            case RotateReason.None:
            case RotateReason.ProductFailed:
            case RotateReason.ProductRejected:
                Require(
                    requestId is not null,
                    "dispatched result is missing request_id.",
                    statusCode);
                Require(
                    dispatched == true,
                    "dispatched result must have dispatched=true.",
                    statusCode);
                break;
        }

        if (result is RotateResult.Changed or
            RotateResult.Unchanged or
            RotateResult.Failed)
        {
            Require(
                operationId is not null,
                "completed PRODUCT result is missing operation_id.",
                statusCode);
        }

        var httpMatches = statusCode switch
        {
            HttpStatusCode.OK =>
                result is RotateResult.Changed or
                    RotateResult.Unchanged or
                    RotateResult.Failed ||
                (result == RotateResult.Rejected &&
                 reason == RotateReason.ProductRejected),

            HttpStatusCode.BadRequest =>
                result == RotateResult.Rejected &&
                reason == RotateReason.InvalidRequest,

            HttpStatusCode.Unauthorized =>
                result == RotateResult.Rejected &&
                reason == RotateReason.Unauthorized,

            HttpStatusCode.MethodNotAllowed =>
                result == RotateResult.Rejected &&
                reason == RotateReason.MethodNotAllowed,

            HttpStatusCode.Conflict =>
                result == RotateResult.Rejected &&
                reason is RotateReason.DeviceOffline or RotateReason.Busy,

            HttpStatusCode.BadGateway =>
                result == RotateResult.Unknown &&
                reason == RotateReason.InternalError,

            HttpStatusCode.GatewayTimeout =>
                result == RotateResult.Unknown &&
                reason == RotateReason.Timeout,

            _ => false,
        };

        Require(
            httpMatches,
            "HTTP status does not match the typed response.",
            statusCode);
    }

    private static RotateResult ParseResult(
        string value,
        HttpStatusCode statusCode) =>
        value switch
        {
            "CHANGED" => RotateResult.Changed,
            "UNCHANGED" => RotateResult.Unchanged,
            "FAILED" => RotateResult.Failed,
            "REJECTED" => RotateResult.Rejected,
            "UNKNOWN" => RotateResult.Unknown,
            _ => throw Protocol($"unknown result '{value}'.", statusCode),
        };

    private static RotateReason ParseReason(
        string value,
        HttpStatusCode statusCode) =>
        value switch
        {
            "NONE" => RotateReason.None,
            "UNAUTHORIZED" => RotateReason.Unauthorized,
            "METHOD_NOT_ALLOWED" => RotateReason.MethodNotAllowed,
            "INVALID_REQUEST" => RotateReason.InvalidRequest,
            "DEVICE_OFFLINE" => RotateReason.DeviceOffline,
            "BUSY" => RotateReason.Busy,
            "PRODUCT_FAILED" => RotateReason.ProductFailed,
            "PRODUCT_REJECTED" => RotateReason.ProductRejected,
            "TIMEOUT" => RotateReason.Timeout,
            "INTERNAL_ERROR" => RotateReason.InternalError,
            _ => throw Protocol($"unknown reason '{value}'.", statusCode),
        };

    private static JsonElement GetRequiredObject(
        JsonElement root,
        string name,
        HttpStatusCode statusCode)
    {
        var element = GetRequiredProperty(root, name, statusCode);
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw Protocol($"'{name}' must be an object.", statusCode);
        }

        return element;
    }

    private static string GetRequiredString(
        JsonElement root,
        string name,
        HttpStatusCode statusCode)
    {
        var element = GetRequiredProperty(root, name, statusCode);
        if (element.ValueKind != JsonValueKind.String)
        {
            throw Protocol($"'{name}' must be a string.", statusCode);
        }

        return element.GetString()!;
    }

    private static string? GetNullableString(
        JsonElement root,
        string name,
        HttpStatusCode statusCode)
    {
        var element = GetRequiredProperty(root, name, statusCode);
        return element.ValueKind switch
        {
            JsonValueKind.Null => null,
            JsonValueKind.String => element.GetString(),
            _ => throw Protocol($"'{name}' must be string|null.", statusCode),
        };
    }

    private static bool GetRequiredBoolean(
        JsonElement root,
        string name,
        HttpStatusCode statusCode)
    {
        var element = GetRequiredProperty(root, name, statusCode);
        if (element.ValueKind is not
            (JsonValueKind.True or JsonValueKind.False))
        {
            throw Protocol($"'{name}' must be boolean.", statusCode);
        }

        return element.GetBoolean();
    }

    private static bool? GetNullableBoolean(
        JsonElement root,
        string name,
        HttpStatusCode statusCode)
    {
        var element = GetRequiredProperty(root, name, statusCode);
        return element.ValueKind switch
        {
            JsonValueKind.Null => null,
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => throw Protocol($"'{name}' must be boolean|null.", statusCode),
        };
    }

    private static long? GetNullablePositiveInt64(
        JsonElement root,
        string name,
        HttpStatusCode statusCode)
    {
        var element = GetRequiredProperty(root, name, statusCode);
        if (element.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (element.ValueKind != JsonValueKind.Number ||
            !element.TryGetInt64(out var value) ||
            value <= 0)
        {
            throw Protocol(
                $"'{name}' must be positive integer|null.",
                statusCode);
        }

        return value;
    }

    private static long GetRequiredNonNegativeInt64(
        JsonElement root,
        string name,
        HttpStatusCode statusCode)
    {
        var element = GetRequiredProperty(root, name, statusCode);
        if (element.ValueKind != JsonValueKind.Number ||
            !element.TryGetInt64(out var value) ||
            value < 0)
        {
            throw Protocol(
                $"'{name}' must be a non-negative integer.",
                statusCode);
        }

        return value;
    }

    private static JsonElement GetRequiredProperty(
        JsonElement root,
        string name,
        HttpStatusCode statusCode)
    {
        if (!root.TryGetProperty(name, out var element))
        {
            throw Protocol(
                $"missing required property '{name}'.",
                statusCode);
        }

        return element;
    }

    private static MishControlProtocolException Protocol(
        string message,
        HttpStatusCode statusCode) =>
        new($"Remote rotation protocol error: {message}", statusCode);

    private static void Require(
        bool condition,
        string message,
        HttpStatusCode statusCode)
    {
        if (!condition)
        {
            throw Protocol(message, statusCode);
        }
    }

    private static string ValidateToken(string managerToken)
    {
        if (string.IsNullOrWhiteSpace(managerToken))
        {
            throw new ArgumentException(
                "Manager token is required.",
                nameof(managerToken));
        }

        if (managerToken.Contains('\r') || managerToken.Contains('\n'))
        {
            throw new ArgumentException(
                "Manager token contains an invalid line break.",
                nameof(managerToken));
        }

        return managerToken;
    }
}
