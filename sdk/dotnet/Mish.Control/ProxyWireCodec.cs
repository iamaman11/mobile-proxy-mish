using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Mish.Control;

internal static class ProxyWireCodec
{
    private static readonly Regex UserNamePattern =
        new(
            "^mish-[0-9a-f]{32}$",
            RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly Regex PasswordPattern =
        new(
            "^[0-9a-f]{64}$",
            RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly string[] SuccessFields =
    [
        "schema",
        "ready",
        "host",
        "ports",
        "username",
        "password",
    ];

    private static readonly string[] FailureFields =
    [
        "schema",
        "ready",
        "reason",
    ];

    private static readonly string[] PortFields =
    [
        "mixed",
        "socks5",
        "http",
    ];

    public static ProxyConnectionResponse Parse(
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
            throw Protocol("response is not valid JSON.", statusCode, exception);
        }

        using (document)
        {
            var root = document.RootElement;
            Require(
                root.ValueKind == JsonValueKind.Object,
                "response root is not an object.",
                statusCode);
            Require(
                StringField(root, "schema", statusCode) ==
                    MishControlClient.ProxySchema,
                "unsupported schema.",
                statusCode);

            var ready = BoolField(root, "ready", statusCode);
            if (ready)
            {
                RequireExactFields(root, SuccessFields, statusCode);
                Require(
                    statusCode == HttpStatusCode.OK,
                    "HTTP status does not match ready response.",
                    statusCode);

                var host = StringField(root, "host", statusCode);
                Require(
                    IPAddress.TryParse(host, out var address) &&
                    address.AddressFamily == AddressFamily.InterNetwork,
                    "host is not an IPv4 address.",
                    statusCode);

                var ports = ObjectField(root, "ports", statusCode);
                RequireExactFields(ports, PortFields, statusCode);
                var mixed = IntField(ports, "mixed", statusCode);
                var socks5 = IntField(ports, "socks5", statusCode);
                var http = IntField(ports, "http", statusCode);
                Require(
                    mixed == 1080 && socks5 == 1081 && http == 3128,
                    "canonical proxy ports are invalid.",
                    statusCode);

                var username = StringField(root, "username", statusCode);
                var password = StringField(root, "password", statusCode);
                Require(
                    UserNamePattern.IsMatch(username),
                    "username has an invalid v1 shape.",
                    statusCode);
                Require(
                    PasswordPattern.IsMatch(password),
                    "password has an invalid v1 shape.",
                    statusCode);

                return new ProxyConnectionResponse(
                    ready: true,
                    ProxyConnectionReason.None,
                    host,
                    new ProxyPorts(mixed, socks5, http),
                    username,
                    password);
            }

            RequireExactFields(root, FailureFields, statusCode);
            var reason = ParseReason(
                StringField(root, "reason", statusCode),
                statusCode);
            ValidateFailureStatus(statusCode, reason);
            return new ProxyConnectionResponse(
                ready: false,
                reason,
                host: null,
                ports: null,
                username: null,
                password: null);
        }
    }

    private static ProxyConnectionReason ParseReason(
        string value,
        HttpStatusCode statusCode) =>
        value switch
        {
            "UNAUTHORIZED" => ProxyConnectionReason.Unauthorized,
            "METHOD_NOT_ALLOWED" => ProxyConnectionReason.MethodNotAllowed,
            "INVALID_REQUEST" => ProxyConnectionReason.InvalidRequest,
            "DEVICE_OFFLINE" => ProxyConnectionReason.DeviceOffline,
            "NOT_READY" => ProxyConnectionReason.NotReady,
            "PROXY_UNAVAILABLE" => ProxyConnectionReason.ProxyUnavailable,
            "CREDENTIAL_UNAVAILABLE" => ProxyConnectionReason.CredentialUnavailable,
            "TIMEOUT" => ProxyConnectionReason.Timeout,
            "INTERNAL_ERROR" => ProxyConnectionReason.InternalError,
            _ => throw Protocol("reason is unknown.", statusCode),
        };

    private static void ValidateFailureStatus(
        HttpStatusCode statusCode,
        ProxyConnectionReason reason)
    {
        var valid = statusCode switch
        {
            HttpStatusCode.BadRequest =>
                reason == ProxyConnectionReason.InvalidRequest,
            HttpStatusCode.Unauthorized =>
                reason == ProxyConnectionReason.Unauthorized,
            HttpStatusCode.MethodNotAllowed =>
                reason == ProxyConnectionReason.MethodNotAllowed,
            HttpStatusCode.ServiceUnavailable =>
                reason is ProxyConnectionReason.DeviceOffline or
                    ProxyConnectionReason.NotReady or
                    ProxyConnectionReason.ProxyUnavailable or
                    ProxyConnectionReason.CredentialUnavailable,
            HttpStatusCode.BadGateway =>
                reason == ProxyConnectionReason.InternalError,
            HttpStatusCode.GatewayTimeout =>
                reason == ProxyConnectionReason.Timeout,
            _ => false,
        };

        Require(
            valid,
            "HTTP status does not match unavailable response.",
            statusCode);
    }

    private static JsonElement ObjectField(
        JsonElement element,
        string name,
        HttpStatusCode statusCode)
    {
        if (!element.TryGetProperty(name, out var value) ||
            value.ValueKind != JsonValueKind.Object)
        {
            throw Protocol($"'{name}' must be an object.", statusCode);
        }
        return value;
    }

    private static string StringField(
        JsonElement element,
        string name,
        HttpStatusCode statusCode)
    {
        if (!element.TryGetProperty(name, out var value) ||
            value.ValueKind != JsonValueKind.String)
        {
            throw Protocol($"'{name}' must be a string.", statusCode);
        }
        return value.GetString()
            ?? throw Protocol($"'{name}' is null.", statusCode);
    }

    private static bool BoolField(
        JsonElement element,
        string name,
        HttpStatusCode statusCode)
    {
        if (!element.TryGetProperty(name, out var value) ||
            (value.ValueKind != JsonValueKind.True &&
             value.ValueKind != JsonValueKind.False))
        {
            throw Protocol($"'{name}' must be a boolean.", statusCode);
        }
        return value.GetBoolean();
    }

    private static int IntField(
        JsonElement element,
        string name,
        HttpStatusCode statusCode)
    {
        if (!element.TryGetProperty(name, out var value) ||
            value.ValueKind != JsonValueKind.Number ||
            !value.TryGetInt32(out var result))
        {
            throw Protocol($"'{name}' must be an integer.", statusCode);
        }
        return result;
    }

    private static void RequireExactFields(
        JsonElement element,
        IEnumerable<string> expected,
        HttpStatusCode statusCode)
    {
        var allowed = new HashSet<string>(
            expected,
            StringComparer.Ordinal);
        var actual = element.EnumerateObject()
            .Select(property => property.Name)
            .ToArray();

        if (actual.Length != allowed.Count ||
            actual.Any(name => !allowed.Contains(name)))
        {
            throw Protocol("response contains unexpected or missing fields.", statusCode);
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
            $"Remote proxy protocol error: {message}",
            statusCode,
            innerException);
}
