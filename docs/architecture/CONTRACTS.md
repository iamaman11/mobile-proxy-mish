# Contract boundaries

```text
same capability + same Rust process
    -> native Rust types

same APK Rust <-> Kotlin
    -> typed FFI projection/commands

cross-process / durable / independently versioned serialized boundary
    -> versioned Protocol Buffers

vendor requiring JSON
    -> explicit JSON quarantine adapter only
```

Protobuf field numbers are permanent, removed fields are reserved, enums use an `UNSPECIFIED = 0` value, and breaking changes require a new major package.

`contracts/proto/` is only a source root. Message ownership stays with the relevant capability package. There is no `common.proto`.

`JSON_QUARANTINE_BOUNDARY` forbids JSON as internal state, IPC, durable configuration, or product contract. sing-box-generated JSON is disposable vendor output.
