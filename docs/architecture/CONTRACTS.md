# Contract boundaries

```text
same capability + same Rust process
    -> native Rust types

same APK Rust <-> Kotlin
    -> typed UniFFI projection / typed platform commands

cross-process / durable / independently versioned serialized boundary
    -> versioned Protocol Buffers

external vendor requiring JSON
    -> explicit JSON quarantine adapter only
```

Protobuf field numbers are permanent, removed fields are reserved, enums use an `UNSPECIFIED = 0` value, and breaking changes require a new major package.

`contracts/proto/` is only a source root. Message ownership remains with the natural capability owner. There is no generic `common.proto` semantic owner.

`JSON_QUARANTINE_BOUNDARY` forbids JSON as internal semantic state, cross-owner IPC, durable PRODUCT configuration or a general PRODUCT contract. JSON is allowed only at an independently required external/vendor/evidence boundary with explicit ownership and validation.

The current Android PRODUCT has no sing-box vendor/config-generation boundary after L8. Historical sing-box configuration files on a development device are LAB residue, not current PRODUCT contracts or durable configuration.
