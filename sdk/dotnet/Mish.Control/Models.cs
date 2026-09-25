using System.Net;

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
    protected MishControlException(
        string message,
        Exception? innerException = null)
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
