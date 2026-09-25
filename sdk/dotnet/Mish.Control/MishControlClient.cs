using System.Net;
using System.Net.Http.Headers;

namespace Mish.Control;

public sealed class MishControlClient : IDisposable
{
    public const string RotateSchema = "mish.control.rotate/v1";

    private const string RotateEndpoint =
        "https://api.alegria.by/v1/rotate";
    private const int MaxResponseBytes = 64 * 1024;

    private static readonly Uri Endpoint =
        new(RotateEndpoint, UriKind.Absolute);
    private static readonly TimeSpan RequestTimeout =
        TimeSpan.FromSeconds(20);

    private readonly HttpClient _httpClient;
    private readonly string _managerToken;

    public MishControlClient(string managerToken)
        : this(CreateDefaultHandler(), managerToken)
    {
    }

    internal MishControlClient(
        HttpMessageHandler handler,
        string managerToken)
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
        request.Headers.Authorization =
            new AuthenticationHeaderValue("Bearer", _managerToken);
        request.Headers.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/json"));

        using var deadline =
            CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken);
        deadline.CancelAfter(RequestTimeout);

        HttpResponseMessage response;
        try
        {
            response = await _httpClient
                .SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    deadline.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException exception)
        {
            throw TransportFailure(
                "Remote rotation transport was cancelled or timed out.",
                exception);
        }
        catch (HttpRequestException exception)
        {
            throw TransportFailure(
                "Remote rotation transport failed.",
                exception);
        }

        using (response)
        {
            if (!string.Equals(
                    response.Content.Headers.ContentType?.MediaType,
                    "application/json",
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new MishControlProtocolException(
                    "Remote rotation response content type is not application/json.",
                    response.StatusCode);
            }

            byte[] body;
            try
            {
                body = await ReadBoundedBodyAsync(
                    response.Content,
                    deadline.Token).ConfigureAwait(false);
            }
            catch (MishControlProtocolException)
            {
                throw;
            }
            catch (OperationCanceledException exception)
            {
                throw TransportFailure(
                    "Remote rotation response body timed out.",
                    exception);
            }
            catch (HttpRequestException exception)
            {
                throw TransportFailure(
                    "Remote rotation response body transport failed.",
                    exception);
            }
            catch (IOException exception)
            {
                throw TransportFailure(
                    "Remote rotation response body transport failed.",
                    exception);
            }

            return RotateWireCodec.Parse(body, response.StatusCode);
        }
    }

    public void Dispose() => _httpClient.Dispose();

    private static SocketsHttpHandler CreateDefaultHandler() =>
        new()
        {
            AllowAutoRedirect = false,
            UseCookies = false,
        };

    private static async Task<byte[]> ReadBoundedBodyAsync(
        HttpContent content,
        CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is long declared &&
            declared > MaxResponseBytes)
        {
            throw new MishControlProtocolException(
                "Remote rotation response exceeds the size bound.");
        }

        await using var stream = await content
            .ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var output = new MemoryStream();

        var buffer = new byte[4096];
        var total = 0;
        while (true)
        {
            var read = await stream
                .ReadAsync(buffer.AsMemory(), cancellationToken)
                .ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            total += read;
            if (total > MaxResponseBytes)
            {
                throw new MishControlProtocolException(
                    "Remote rotation response exceeds the size bound.");
            }

            output.Write(buffer, 0, read);
        }

        return output.ToArray();
    }

    private static MishControlTransportException TransportFailure(
        string message,
        Exception innerException) =>
        new(
            message +
            " Never replay automatically because the command may have been dispatched.",
            operationOutcomeMayBeUnknown: true,
            innerException);

    private static string ValidateToken(string managerToken)
    {
        if (string.IsNullOrWhiteSpace(managerToken))
        {
            throw new ArgumentException(
                "Manager token is required.",
                nameof(managerToken));
        }

        if (managerToken.Contains('\r') ||
            managerToken.Contains('\n'))
        {
            throw new ArgumentException(
                "Manager token contains an invalid line break.",
                nameof(managerToken));
        }

        return managerToken;
    }
}
