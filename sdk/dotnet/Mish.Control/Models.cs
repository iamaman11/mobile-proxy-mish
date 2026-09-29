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

public enum ProxyConnectionReason
{
    None,
    Unauthorized,
    MethodNotAllowed,
    InvalidRequest,
    DeviceOffline,
    NotReady,
    ProxyUnavailable,
    CredentialUnavailable,
    Timeout,
    InternalError,
}

public sealed record ProxyPorts(
    int Mixed,
    int Socks5,
    int Http);

public sealed class ProxyConnectionResponse
{
    internal ProxyConnectionResponse(
        bool ready,
        ProxyConnectionReason reason,
        string? host,
        ProxyPorts? ports,
        string? username,
        string? password)
    {
        Ready = ready;
        Reason = reason;
        Host = host;
        Ports = ports;
        Username = username;
        Password = password;
    }

    public bool Ready { get; }

    public ProxyConnectionReason Reason { get; }

    public string? Host { get; }

    public ProxyPorts? Ports { get; }

    public string? Username { get; }

    public string? Password { get; }

    public override string ToString() =>
        Ready
            ? $"ProxyConnectionResponse(Ready=true,Host={Host},<credentials-redacted>)"
            : $"ProxyConnectionResponse(Ready=false,Reason={Reason})";
}

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
