# LAB-2 acceptance boundary

LAB-2 proves the release-consumer control surface before a phone is introduced.

Hosted Windows acceptance must prove:

```text
exact published RC metadata is resolvable by tag
exact APK/manifest names are unambiguous
GitHub asset SHA-256 matches the authorized digest
manifest tag/source/digest/signing identity matches the authorized tuple
downloaded APK SHA-256 matches the authorized digest
verification receipt is typed and fail-closed
evidence projection is allowlisted
stale/tampered APK cannot pass the install gate
subprocess execution has a bounded timeout
no Android product build tool is invoked by labctl
```

Physical Windows acceptance later in LAB-2 is host-only and phone-absent. It must prove the same exact RC can be resolved and verified through the accepted self-hosted runner using the LAB-owned PowerShell runtime. It does not build, install, or test the APK.

A physical PASS does not escalate to E3 and does not authorize PHONE-ON by itself; #27 and #28 remain sequential prerequisites.
