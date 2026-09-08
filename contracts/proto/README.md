# Versioned product contracts

This is the canonical source root for serialized Protobuf boundaries that are actually justified by A10.

Schemas are grouped by the owning capability and major package version, for example:

```text
mish/configuration/v1/...
mish/rotation/v1/...
mish/runtime/v1/...
```

Do not create `common.proto`, generic message buckets, or Protobuf wrappers for ordinary same-process Rust calls. No schema is added in B1 because no serialized product boundary has yet been implemented.
