using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Mish.Control;

internal static class RotateWireCodec
{
    private static readonly Regex RequestIdPattern =
        new(
            "^mgr_[0-9a-f]{32}$",
            RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly JsonSerializerOptions JsonOptions =
        new()
        {
            PropertyNameCaseInsensitive = false,
        };

    private static readonly string[] RequiredTopLevelFields =
    [
        "schema",
        "request_id",
        "terminal",
        "result",
        "reason",
        "operation_id",
        "changed",
        "device_online",
        "dispatched",
        "retryable",
        "timing",
    ];

    private static readonly string[] RequiredTimingFields =
    [
        "started_at_ms",
        "completed_at_ms",
        "duration_ms",
    ];

    public static RotateIpResponse Parse(
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
            throw Protocol(
                "response is not valid JSON.",
                statusCode,
                exception);
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw Protocol(
                    "response root is not an object.",
                    statusCode);
            }

            RequireFields(root, RequiredTopLevelFields, statusCode);
            var timingElement = root.GetProperty("timing");
            if (timingElement.ValueKind != JsonValueKind.Object)
            {
                throw Protocol(
                    "timing must be an object.",
                    statusCode);
            }

            RequireFields(
                timingElement,
                RequiredTimingFields,
                statusCode);

            WireResponse wire;
            try
            {
                wire = JsonSerializer.Deserialize<WireResponse>(
                    root.GetRawText(),
                    JsonOptions)
                    ?? throw new JsonException("response is null");
            }
            catch (JsonException exception)
            {
                throw Protocol(
                    "response field types are invalid.",
                    statusCode,
                    exception);
            }

            return Validate(wire, statusCode);
        }
    }

    private static RotateIpResponse Validate(
        WireResponse wire,
        HttpStatusCode statusCode)
    {
        Require(
            wire.Schema == MishControlClient.RotateSchema,
            "unsupported schema.",
            statusCode);
        Require(
            wire.Terminal.HasValue &&
            wire.Retryable.HasValue &&
            wire.Timing is not null &&
            wire.Timing.StartedAtMs.HasValue &&
            wire.Timing.CompletedAtMs.HasValue &&
            wire.Timing.DurationMs.HasValue,
            "required fields are null.",
            statusCode);

        if (wire.RequestId is not null)
        {
            Require(
                RequestIdPattern.IsMatch(wire.RequestId),
                "request_id has an invalid v1 shape.",
                statusCode);
        }

        if (wire.OperationId is not null)
        {
            Require(
                wire.OperationId > 0,
                "operation_id must be positive.",
                statusCode);
        }

        var result = ParseResult(wire.Result, statusCode);
        var reason = ParseReason(wire.Reason, statusCode);

        var startedAtMs = wire.Timing.StartedAtMs.Value;
        var completedAtMs = wire.Timing.CompletedAtMs.Value;
        var durationMs = wire.Timing.DurationMs.Value;

        Require(
            startedAtMs >= 0 &&
            completedAtMs >= startedAtMs &&
            durationMs >= 0 &&
            completedAtMs - startedAtMs == durationMs,
            "timing is inconsistent.",
            statusCode);

        var terminal = wire.Terminal.Value;
        var retryable = wire.Retryable.Value;

        Require(
            terminal == (result != RotateResult.Unknown),
            "terminal does not match result.",
            statusCode);

        var expectedChanged = result switch
        {
            RotateResult.Changed => true,
            RotateResult.Unchanged => false,
            _ => (bool?)null,
        };
        Require(
            wire.Changed == expectedChanged,
            "changed does not match result.",
            statusCode);

        var expectedRetryable =
            wire.Dispatched == false &&
            (reason is RotateReason.DeviceOffline or RotateReason.Busy);
        Require(
            retryable == expectedRetryable,
            "retryable does not match reason/dispatch.",
            statusCode);

        ValidateReason(
            wire,
            result,
            reason,
            statusCode);
        ValidateHttpStatus(
            statusCode,
            result,
            reason);

        return new RotateIpResponse(
            wire.RequestId,
            terminal,
            result,
            reason,
            wire.OperationId,
            wire.Changed,
            wire.DeviceOnline,
            wire.Dispatched,
            retryable,
            new RotateIpTiming(
                startedAtMs,
                completedAtMs,
                durationMs));
    }

    private static void ValidateReason(
        WireResponse wire,
        RotateResult result,
        RotateReason reason,
        HttpStatusCode statusCode)
    {
        var reasonMatchesResult = reason switch
        {
            RotateReason.None =>
                result is RotateResult.Changed or
                    RotateResult.Unchanged,
            RotateReason.ProductFailed =>
                result == RotateResult.Failed,
            RotateReason.ProductRejected or
            RotateReason.Unauthorized or
            RotateReason.MethodNotAllowed or
            RotateReason.InvalidRequest or
            RotateReason.DeviceOffline or
            RotateReason.Busy =>
                result == RotateResult.Rejected,
            RotateReason.Timeout or
            RotateReason.InternalError =>
                result == RotateResult.Unknown,
            _ => false,
        };
        Require(
            reasonMatchesResult,
            "reason does not match result.",
            statusCode);

        switch (reason)
        {
            case RotateReason.Unauthorized:
            case RotateReason.MethodNotAllowed:
            case RotateReason.InvalidRequest:
                Require(
                    wire.RequestId is null &&
                    wire.OperationId is null &&
                    wire.Dispatched == false,
                    "pre-correlation rejection is inconsistent.",
                    statusCode);
                break;

            case RotateReason.DeviceOffline:
                Require(
                    wire.RequestId is not null &&
                    wire.OperationId is null &&
                    wire.Dispatched == false &&
                    wire.DeviceOnline == false,
                    "DEVICE_OFFLINE is inconsistent.",
                    statusCode);
                break;

            case RotateReason.Busy:
                Require(
                    wire.RequestId is not null &&
                    wire.OperationId is null &&
                    wire.Dispatched == false,
                    "BUSY is inconsistent.",
                    statusCode);
                break;

            case RotateReason.InternalError:
                Require(
                    wire.RequestId is not null &&
                    wire.Dispatched is null &&
                    wire.DeviceOnline is null,
                    "INTERNAL_ERROR is inconsistent.",
                    statusCode);
                break;

            case RotateReason.Timeout:
                Require(
                    wire.RequestId is not null &&
                    wire.Dispatched == true,
                    "TIMEOUT is inconsistent.",
                    statusCode);
                break;

            case RotateReason.None:
            case RotateReason.ProductFailed:
            case RotateReason.ProductRejected:
                Require(
                    wire.RequestId is not null &&
                    wire.Dispatched == true,
                    "dispatched result is inconsistent.",
                    statusCode);
                break;
        }

        if (result is RotateResult.Changed or
            RotateResult.Unchanged or
            RotateResult.Failed)
        {
            Require(
                wire.OperationId is not null,
                "completed PRODUCT result lacks operation_id.",
                statusCode);
        }
    }

    private static void ValidateHttpStatus(
        HttpStatusCode statusCode,
        RotateResult result,
        RotateReason reason)
    {
        var valid = statusCode switch
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
                (reason is RotateReason.DeviceOffline or
                    RotateReason.Busy),
            HttpStatusCode.BadGateway =>
                result == RotateResult.Unknown &&
                reason == RotateReason.InternalError,
            HttpStatusCode.GatewayTimeout =>
                result == RotateResult.Unknown &&
                reason == RotateReason.Timeout,
            _ => false,
        };

        Require(
            valid,
            "HTTP status does not match typed response.",
            statusCode);
    }

    private static RotateResult ParseResult(
        string? value,
        HttpStatusCode statusCode) =>
        value switch
        {
            "CHANGED" => RotateResult.Changed,
            "UNCHANGED" => RotateResult.Unchanged,
            "FAILED" => RotateResult.Failed,
            "REJECTED" => RotateResult.Rejected,
            "UNKNOWN" => RotateResult.Unknown,
            _ => throw Protocol(
                "result is unknown.",
                statusCode),
        };

    private static RotateReason ParseReason(
        string? value,
        HttpStatusCode statusCode) =>
        value switch
        {
            "NONE" => RotateReason.None,
            "UNAUTHORIZED" => RotateReason.Unauthorized,
            "METHOD_NOT_ALLOWED" =>
                RotateReason.MethodNotAllowed,
            "INVALID_REQUEST" =>
                RotateReason.InvalidRequest,
            "DEVICE_OFFLINE" =>
                RotateReason.DeviceOffline,
            "BUSY" => RotateReason.Busy,
            "PRODUCT_FAILED" =>
                RotateReason.ProductFailed,
            "PRODUCT_REJECTED" =>
                RotateReason.ProductRejected,
            "TIMEOUT" => RotateReason.Timeout,
            "INTERNAL_ERROR" =>
                RotateReason.InternalError,
            _ => throw Protocol(
                "reason is unknown.",
                statusCode),
        };

    private static void RequireFields(
        JsonElement element,
        IEnumerable<string> names,
        HttpStatusCode statusCode)
    {
        foreach (var name in names)
        {
            if (!element.TryGetProperty(name, out _))
            {
                throw Protocol(
                    $"missing required field '{name}'.",
                    statusCode);
            }
        }
    }

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

    private static MishControlProtocolException Protocol(
        string message,
        HttpStatusCode statusCode,
        Exception? innerException = null) =>
        new(
            $"Remote rotation protocol error: {message}",
            statusCode,
            innerException);

    private sealed class WireResponse
    {
        [JsonPropertyName("schema")]
        public string? Schema { get; init; }

        [JsonPropertyName("request_id")]
        public string? RequestId { get; init; }

        [JsonPropertyName("terminal")]
        public bool? Terminal { get; init; }

        [JsonPropertyName("result")]
        public string? Result { get; init; }

        [JsonPropertyName("reason")]
        public string? Reason { get; init; }

        [JsonPropertyName("operation_id")]
        public long? OperationId { get; init; }

        [JsonPropertyName("changed")]
        public bool? Changed { get; init; }

        [JsonPropertyName("device_online")]
        public bool? DeviceOnline { get; init; }

        [JsonPropertyName("dispatched")]
        public bool? Dispatched { get; init; }

        [JsonPropertyName("retryable")]
        public bool? Retryable { get; init; }

        [JsonPropertyName("timing")]
        public WireTiming? Timing { get; init; }
    }

    private sealed class WireTiming
    {
        [JsonPropertyName("started_at_ms")]
        public long? StartedAtMs { get; init; }

        [JsonPropertyName("completed_at_ms")]
        public long? CompletedAtMs { get; init; }

        [JsonPropertyName("duration_ms")]
        public long? DurationMs { get; init; }
    }
}
