using System.Net;
using System.Reflection;
using System.Text;
using System.Text.Json;
using Mish.Control;

namespace Mish.Control.ContractTests;

internal static class Program
{
    private const string Token =
        "mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm";
    private const string RequestId =
        "mgr_0123456789abcdef0123456789abcdef";

    private static async Task<int> Main()
    {
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("CHANGED", TestChangedAsync),
            ("UNCHANGED_NO_RETRY", TestUnchangedAsync),
            ("FAILED", TestFailedAsync),
            ("REJECTED_DEVICE_OFFLINE", TestRejectedDeviceOfflineAsync),
            ("REJECTED_BUSY", TestRejectedBusyAsync),
            ("UNKNOWN_TIMEOUT_NO_REPLAY", TestUnknownTimeoutAsync),
            ("UNKNOWN_INTERNAL_ERROR", TestUnknownInternalErrorAsync),
            ("AUTH_REJECTION_TYPED", TestUnauthorizedAsync),
            ("UNKNOWN_SCHEMA", TestUnknownSchemaAsync),
            ("UNKNOWN_REASON", TestUnknownReasonAsync),
            ("MALFORMED_JSON", TestMalformedJsonAsync),
            ("TRANSPORT_FAILURE_NO_RETRY", TestTransportFailureAsync),
            ("HTTP_BODY_STATUS_MISMATCH", TestStatusMismatchAsync),
            ("REDIRECT_NO_REPLAY", TestRedirectAsync),
            ("ONE_EMPTY_POST", TestOnePostAsync),
            ("PUBLIC_REQUEST_SURFACE", TestPublicRequestSurfaceAsync),
        };

        var failures = 0;
        foreach (var test in tests)
        {
            try
            {
                await test.Run();
                Console.WriteLine($"PASS {test.Name}");
            }
            catch (Exception exception)
            {
                failures++;
                Console.Error.WriteLine(
                    $"FAIL {test.Name}: {exception.GetType().Name}: {exception.Message}");
            }
        }

        Console.WriteLine(
            $"MISH_CONTROL_SDK_CONTRACT_TESTS={tests.Length - failures}/{tests.Length}");
        return failures == 0 ? 0 : 1;
    }

    private static async Task TestChangedAsync()
    {
        var handler = JsonHandler(
            HttpStatusCode.OK,
            Payload(
                terminal: true,
                result: "CHANGED",
                reason: "NONE",
                operationId: 9,
                changed: true,
                deviceOnline: true,
                dispatched: true,
                retryable: false));

        using var client = NewClient(handler);
        var response = await client.RotateIpAsync();

        Equal(RotateResult.Changed, response.Result, "result");
        Equal(RotateReason.None, response.Reason, "reason");
        Equal(true, response.Terminal, "terminal");
        Equal<bool?>(true, response.Changed, "changed");
        Equal<long?>(9, response.OperationId, "operation_id");
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestUnchangedAsync()
    {
        var handler = JsonHandler(
            HttpStatusCode.OK,
            Payload(
                terminal: true,
                result: "UNCHANGED",
                reason: "NONE",
                operationId: 10,
                changed: false,
                deviceOnline: true,
                dispatched: true,
                retryable: false));

        using var client = NewClient(handler);
        var response = await client.RotateIpAsync();

        Equal(RotateResult.Unchanged, response.Result, "result");
        Equal<bool?>(false, response.Changed, "changed");
        Equal(false, response.Retryable, "retryable");
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestFailedAsync()
    {
        var handler = JsonHandler(
            HttpStatusCode.OK,
            Payload(
                terminal: true,
                result: "FAILED",
                reason: "PRODUCT_FAILED",
                operationId: 11,
                changed: null,
                deviceOnline: true,
                dispatched: true,
                retryable: false));

        using var client = NewClient(handler);
        var response = await client.RotateIpAsync();

        Equal(RotateResult.Failed, response.Result, "result");
        Equal(RotateReason.ProductFailed, response.Reason, "reason");
        Equal<bool?>(null, response.Changed, "changed");
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestRejectedDeviceOfflineAsync()
    {
        var handler = JsonHandler(
            HttpStatusCode.Conflict,
            Payload(
                terminal: true,
                result: "REJECTED",
                reason: "DEVICE_OFFLINE",
                operationId: null,
                changed: null,
                deviceOnline: false,
                dispatched: false,
                retryable: true));

        using var client = NewClient(handler);
        var response = await client.RotateIpAsync();

        Equal(RotateResult.Rejected, response.Result, "result");
        Equal(RotateReason.DeviceOffline, response.Reason, "reason");
        Equal(true, response.Retryable, "retryable");
        Equal<bool?>(false, response.Dispatched, "dispatched");
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestRejectedBusyAsync()
    {
        var handler = JsonHandler(
            HttpStatusCode.Conflict,
            Payload(
                terminal: true,
                result: "REJECTED",
                reason: "BUSY",
                operationId: null,
                changed: null,
                deviceOnline: true,
                dispatched: false,
                retryable: true));

        using var client = NewClient(handler);
        var response = await client.RotateIpAsync();

        Equal(RotateReason.Busy, response.Reason, "reason");
        Equal(true, response.Retryable, "retryable");
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestUnknownTimeoutAsync()
    {
        var handler = JsonHandler(
            HttpStatusCode.GatewayTimeout,
            Payload(
                terminal: false,
                result: "UNKNOWN",
                reason: "TIMEOUT",
                operationId: 12,
                changed: null,
                deviceOnline: false,
                dispatched: true,
                retryable: false));

        using var client = NewClient(handler);
        var response = await client.RotateIpAsync();

        Equal(RotateResult.Unknown, response.Result, "result");
        Equal(RotateReason.Timeout, response.Reason, "reason");
        Equal(false, response.Terminal, "terminal");
        Equal(false, response.Retryable, "retryable");
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestUnknownInternalErrorAsync()
    {
        var handler = JsonHandler(
            HttpStatusCode.BadGateway,
            Payload(
                terminal: false,
                result: "UNKNOWN",
                reason: "INTERNAL_ERROR",
                operationId: null,
                changed: null,
                deviceOnline: null,
                dispatched: null,
                retryable: false));

        using var client = NewClient(handler);
        var response = await client.RotateIpAsync();

        Equal(RotateResult.Unknown, response.Result, "result");
        Equal(RotateReason.InternalError, response.Reason, "reason");
        Equal<bool?>(null, response.Dispatched, "dispatched");
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestUnauthorizedAsync()
    {
        var handler = JsonHandler(
            HttpStatusCode.Unauthorized,
            Payload(
                terminal: true,
                result: "REJECTED",
                reason: "UNAUTHORIZED",
                operationId: null,
                changed: null,
                deviceOnline: null,
                dispatched: false,
                retryable: false,
                requestId: null));

        using var client = NewClient(handler);
        var response = await client.RotateIpAsync();

        Equal(RotateResult.Rejected, response.Result, "result");
        Equal(RotateReason.Unauthorized, response.Reason, "reason");
        Equal<string?>(null, response.RequestId, "request_id");
        Equal<bool?>(false, response.Dispatched, "dispatched");
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestUnknownSchemaAsync()
    {
        var handler = JsonHandler(
            HttpStatusCode.OK,
            Payload(
                terminal: true,
                result: "CHANGED",
                reason: "NONE",
                operationId: 1,
                changed: true,
                deviceOnline: true,
                dispatched: true,
                retryable: false,
                schema: "mish.control.rotate/v2"));

        using var client = NewClient(handler);
        await ThrowsAsync<MishControlProtocolException>(
            () => client.RotateIpAsync());
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestUnknownReasonAsync()
    {
        var handler = JsonHandler(
            HttpStatusCode.OK,
            Payload(
                terminal: true,
                result: "CHANGED",
                reason: "SOMETHING_NEW",
                operationId: 1,
                changed: true,
                deviceOnline: true,
                dispatched: true,
                retryable: false));

        using var client = NewClient(handler);
        await ThrowsAsync<MishControlProtocolException>(
            () => client.RotateIpAsync());
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestMalformedJsonAsync()
    {
        var handler = JsonHandler(HttpStatusCode.OK, "{not-json");
        using var client = NewClient(handler);

        await ThrowsAsync<MishControlProtocolException>(
            () => client.RotateIpAsync());
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestTransportFailureAsync()
    {
        var handler = new RecordingHandler(
            (_, _) => throw new HttpRequestException(
                "synthetic transport failure"));
        using var client = NewClient(handler);

        var exception = await ThrowsAsync<MishControlTransportException>(
            () => client.RotateIpAsync());

        Equal(
            true,
            exception.OperationOutcomeMayBeUnknown,
            "operation_outcome_may_be_unknown");
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestStatusMismatchAsync()
    {
        var handler = JsonHandler(
            HttpStatusCode.Conflict,
            Payload(
                terminal: true,
                result: "CHANGED",
                reason: "NONE",
                operationId: 3,
                changed: true,
                deviceOnline: true,
                dispatched: true,
                retryable: false));

        using var client = NewClient(handler);
        await ThrowsAsync<MishControlProtocolException>(
            () => client.RotateIpAsync());
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestRedirectAsync()
    {
        var handler = new RecordingHandler((_, _) =>
        {
            var response = new HttpResponseMessage(
                HttpStatusCode.TemporaryRedirect)
            {
                Content = new StringContent(
                    "redirect",
                    Encoding.UTF8,
                    "text/plain"),
            };
            response.Headers.Location =
                new Uri("https://example.invalid/other");
            return Task.FromResult(response);
        });

        using var client = NewClient(handler);
        await ThrowsAsync<MishControlProtocolException>(
            () => client.RotateIpAsync());
        Equal(1, handler.SendCount, "send_count");
    }

    private static async Task TestOnePostAsync()
    {
        var handler = JsonHandler(
            HttpStatusCode.OK,
            Payload(
                terminal: true,
                result: "CHANGED",
                reason: "NONE",
                operationId: 4,
                changed: true,
                deviceOnline: true,
                dispatched: true,
                retryable: false));

        using var client = NewClient(handler);
        _ = await client.RotateIpAsync();

        Equal(1, handler.SendCount, "send_count");
        Equal(HttpMethod.Post, handler.LastMethod, "method");
        Equal(
            "https://api.alegria.by/v1/rotate",
            handler.LastUri?.AbsoluteUri,
            "uri");
        Equal<int?>(0, handler.LastBodyLength, "body_length");
        Equal("Bearer", handler.LastAuthorizationScheme, "auth_scheme");
        Equal(Token, handler.LastAuthorizationParameter, "auth_token");
        Equal(HttpVersion.Version11, handler.LastVersion, "http_version");
        Equal(
            HttpVersionPolicy.RequestVersionExact,
            handler.LastVersionPolicy,
            "http_version_policy");
    }

    private static Task TestPublicRequestSurfaceAsync()
    {
        var requestType = typeof(RotateIpRequest);
        Equal(
            0,
            requestType.GetConstructors(
                BindingFlags.Instance | BindingFlags.Public).Length,
            "request_public_ctor_count");
        Equal(
            0,
            requestType.GetProperties(
                BindingFlags.Instance | BindingFlags.Public).Length,
            "request_instance_property_count");

        var rotateMethods = typeof(MishControlClient)
            .GetMethods(BindingFlags.Instance | BindingFlags.Public)
            .Where(method =>
                method.Name == nameof(MishControlClient.RotateIpAsync))
            .ToArray();

        Equal(1, rotateMethods.Length, "rotate_method_count");
        var parameters = rotateMethods[0].GetParameters();
        Equal(1, parameters.Length, "rotate_parameter_count");
        Equal(
            typeof(CancellationToken),
            parameters[0].ParameterType,
            "rotate_parameter_type");
        Equal(
            true,
            parameters[0].HasDefaultValue,
            "cancellation_has_default");

        return Task.CompletedTask;
    }

    private static MishControlClient NewClient(RecordingHandler handler) =>
        new(handler, Token);

    private static RecordingHandler JsonHandler(
        HttpStatusCode status,
        string json) =>
        new((_, _) => Task.FromResult(new HttpResponseMessage(status)
        {
            Content = new StringContent(
                json,
                Encoding.UTF8,
                "application/json"),
        }));

    private static string Payload(
        bool terminal,
        string result,
        string reason,
        long? operationId,
        bool? changed,
        bool? deviceOnline,
        bool? dispatched,
        bool retryable,
        string? requestId = RequestId,
        string schema = MishControlClient.RotateSchema,
        long startedAtMs = 100,
        long completedAtMs = 140)
    {
        return JsonSerializer.Serialize(new
        {
            schema,
            request_id = requestId,
            terminal,
            result,
            reason,
            operation_id = operationId,
            changed,
            device_online = deviceOnline,
            dispatched,
            retryable,
            timing = new
            {
                started_at_ms = startedAtMs,
                completed_at_ms = completedAtMs,
                duration_ms = completedAtMs - startedAtMs,
            },
        });
    }

    private static async Task<TException> ThrowsAsync<TException>(
        Func<Task> action)
        where TException : Exception
    {
        try
        {
            await action();
        }
        catch (TException exception)
        {
            return exception;
        }

        throw new InvalidOperationException(
            $"Expected exception {typeof(TException).Name}.");
    }

    private static void Equal<T>(
        T expected,
        T actual,
        string name)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException(
                $"{name}: expected={Format(expected)} actual={Format(actual)}");
        }
    }

    private static string Format<T>(T value) =>
        value is null ? "<null>" : value.ToString() ?? "<null>";

    internal sealed class RecordingHandler : HttpMessageHandler
    {
        private readonly Func<
            HttpRequestMessage,
            CancellationToken,
            Task<HttpResponseMessage>> _responder;

        public RecordingHandler(
            Func<
                HttpRequestMessage,
                CancellationToken,
                Task<HttpResponseMessage>> responder)
        {
            _responder = responder;
        }

        public int SendCount { get; private set; }

        public HttpMethod? LastMethod { get; private set; }

        public Uri? LastUri { get; private set; }

        public int? LastBodyLength { get; private set; }

        public string? LastAuthorizationScheme { get; private set; }

        public string? LastAuthorizationParameter { get; private set; }

        public Version? LastVersion { get; private set; }

        public HttpVersionPolicy? LastVersionPolicy { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            SendCount++;
            LastMethod = request.Method;
            LastUri = request.RequestUri;
            LastAuthorizationScheme =
                request.Headers.Authorization?.Scheme;
            LastAuthorizationParameter =
                request.Headers.Authorization?.Parameter;
            LastVersion = request.Version;
            LastVersionPolicy = request.VersionPolicy;
            LastBodyLength = request.Content is null
                ? null
                : (await request.Content
                    .ReadAsByteArrayAsync(cancellationToken)).Length;

            return await _responder(request, cancellationToken);
        }
    }
}
