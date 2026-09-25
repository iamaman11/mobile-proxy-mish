# MISH Control SDK (.NET 8)

This is a thin consumer adapter for the accepted public remote-rotation API.

It does not own Rotation, retries, polling, WSS, device identity, Android state, Cloudflare Durable Object lifecycle, or PRODUCT recovery.

## Consumer API

```csharp
using Mish.Control;

using var client = new MishControlClient(managerToken);

RotateIpResponse result = await client.RotateIpAsync();
```

The consumer supplies only the manager token. The endpoint, HTTP method, empty request body, wire schema, correlation details, and protocol mapping stay inside the SDK.

## Result semantics

```text
CHANGED
  rotation completed correctly and public egress changed

UNCHANGED
  rotation completed correctly but the carrier returned the same public egress

FAILED
  PRODUCT accepted the operation but could not complete it correctly

REJECTED
  operation was not accepted or PRODUCT explicitly rejected it

UNKNOWN
  the outcome cannot be established truthfully
```

`UNCHANGED` is a normal completed result. It is not a reason to retry.

`UNKNOWN` must never be replayed automatically.

## Safety contract

```text
one RotateIpAsync()
 -> one SDK HTTP send
 -> POST https://mish.alegria.by/v1/rotate
 -> empty body
 -> no polling
 -> no SDK retry
 -> no redirect replay
 -> no replay after UNKNOWN
```

The SDK uses exact HTTP/1.1 for this command and disables automatic redirects.

`retryable=true` is information for the calling application only. The SDK does not act on it.

A transport failure throws `MishControlTransportException` with `OperationOutcomeMayBeUnknown=true`. The caller must not automatically replay the operation because the request may already have crossed the public API boundary.

## Typed response

```csharp
RotateIpResponse {
    string? RequestId;
    bool Terminal;
    RotateResult Result;
    RotateReason Reason;
    long? OperationId;
    bool? Changed;
    bool? DeviceOnline;
    bool? Dispatched;
    bool Retryable;
    RotateIpTiming Timing;
}
```

The SDK recognizes exactly wire schema:

```text
mish.control.rotate/v1
```

and typed results:

```text
CHANGED
UNCHANGED
FAILED
REJECTED
UNKNOWN
```

with all currently supported `RotateReason` values.

## Protocol errors

The SDK fails closed with `MishControlProtocolException` for:

- unknown schema/version;
- malformed JSON;
- unknown result/reason;
- missing or mistyped required fields;
- inconsistent terminal/changed/retryable semantics;
- inconsistent timing;
- HTTP status/body mismatch;
- redirect or other non-JSON response;
- oversized response body.

Valid typed `FAILED`, `REJECTED`, and `UNKNOWN` responses are returned as `RotateIpResponse`; they are not converted into parsing exceptions.

Authentication rejection is therefore represented as:

```text
Result = REJECTED
Reason = UNAUTHORIZED
Dispatched = false
```

## Request model

`RotateIpRequest` is an intentionally parameterless marker. `RotateIpAsync()` accepts no public command payload.

The consumer cannot supply:

- request_id;
- operation_id;
- device_id;
- WSS/session details;
- Android/PRODUCT internals.

## Token handling

The caller supplies the manager token. The SDK places it in the Authorization header and does not log or persist it.

## Tests

```bash
dotnet run \
  --project sdk/dotnet/Mish.Control.ContractTests/Mish.Control.ContractTests.csproj \
  --configuration Release
```

The deterministic harness uses no DEVICE-1 and sends no real rotation. It verifies typed result/error mapping and the one-send/no-replay client contract.
