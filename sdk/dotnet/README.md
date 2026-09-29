# MISH Control SDK (.NET 8)

This is the thin common client for the public MISH operator API at `mish.alegria.by`.

The same SDK contract is used by local Windows agents and remote clients. Normal operation does not use ADB and callers never provide device, request, operation, credential or WebSocket identifiers.

## Consumer API

```csharp
using Mish.Control;

using var client = new MishControlClient(managerToken);

ProxyConnectionResponse proxy = await client.GetProxyAsync();
RotateIpResponse rotation = await client.RotateIpAsync();
```

The caller supplies only the manager Bearer token.

## Get current proxy

`GetProxyAsync()` performs exactly one read-only request:

```text
GET https://mish.alegria.by/v1/proxy
Authorization: Bearer <token>
body: none
query: none
```

A ready response contains only connection data the consumer needs:

```text
host
ports.mixed = 1080
ports.socks5 = 1081
ports.http = 3128
username
password
```

The endpoint and credential material come from the current PRODUCT generation. The SDK does not cache, persist, rotate or synthesize them.

An unavailable response is typed through `ProxyConnectionReason` and contains no partial credentials.

`ProxyConnectionResponse.ToString()` deliberately redacts credentials.

A proxy-read transport failure has `OperationOutcomeMayBeUnknown=false`: the read is non-mutating. The SDK still performs no hidden retry; a caller may explicitly issue a later read.

## Rotate IP

`RotateIpAsync()` performs exactly one mutation request:

```text
POST https://mish.alegria.by/v1/rotate
Authorization: Bearer <token>
body: empty
```

Result semantics:

```text
CHANGED    rotation completed and public egress changed
UNCHANGED  rotation completed but carrier returned the same public egress
FAILED     PRODUCT accepted the operation but could not complete it
REJECTED   operation was not accepted or PRODUCT explicitly rejected it
UNKNOWN    mutation outcome cannot be established truthfully
```

`UNCHANGED` is a normal completed result. `UNKNOWN` must never be replayed automatically.

A rotation transport failure has `OperationOutcomeMayBeUnknown=true`, because the command may already have crossed the public API boundary.

## Safety contract

```text
GetProxyAsync()
 -> one GET
 -> no body/query
 -> no polling
 -> no SDK retry
 -> no redirect replay

RotateIpAsync()
 -> one POST
 -> empty body
 -> no polling
 -> no SDK retry
 -> no redirect replay
 -> no replay after UNKNOWN
```

The SDK uses exact HTTP/1.1 and disables automatic redirects.

The consumer cannot supply:

- request_id;
- operation_id;
- device_id;
- credential_id/version;
- Mesh admission epoch;
- WSS/session details;
- Android/PRODUCT internals.

## Wire schemas

```text
mish.proxy/v1
mish.control.rotate/v1
```

Malformed JSON, unknown schemas/reasons, invalid fields, HTTP/body mismatches, redirects and oversized responses fail closed with `MishControlProtocolException`.

## Token handling

The caller supplies the manager token. The SDK places it only in the Authorization header and does not log or persist it.

Proxy credentials returned by `GetProxyAsync()` are intentionally exposed to the calling process because they are the requested connection material. The SDK itself does not persist or log them.

## Tests

```bash
dotnet run \
  --project sdk/dotnet/Mish.Control.ContractTests/Mish.Control.ContractTests.csproj \
  --configuration Release
```

The deterministic harness uses no physical device and verifies the one-send/no-replay request surfaces, typed responses, strict schemas and credential redaction behavior.
