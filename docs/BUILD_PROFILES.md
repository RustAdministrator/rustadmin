# RustAdmin Shipping Build Profiles

`scripts/platform_profiles.toml` is the declarative source for shipping RustAdmin target profiles. It records target triples, roles, Cargo feature constraints, native components and platform markers, minimum OS versions, packaging paths, wrapper ownership, and required gates.

The matrix also mirrors Cargo's default feature set. Validation fails if `Cargo.toml` changes those defaults without the profiles being reviewed.

Validate the matrix and its negative cases before using a release wrapper:

```bash
python3 scripts/platform_profiles.py validate
bash scripts/test_platform_profiles.sh
```

Target wrappers call the validator before Cargo or platform packaging. A direct check is also available:

```bash
python3 scripts/platform_profiles.py check \
  --profile android-arm64 \
  --wrapper flutter/ndk_arm64.sh \
  --target aarch64-linux-android \
  --abi arm64-v8a \
  --features flutter,hwcodec,mediacodec
```

The matrix validates configuration; it does not replace platform toolchains. Existing wrappers remain responsible for locating native prefixes and verifying/consuming their platform artifacts. Cargo compile-time invariants provide a second boundary for target-specific features.

Every profile declares these gates:

- `config`: matrix, wrapper ownership, target, ABI, and feature validation;
- `compile`: Cargo compilation for the selected target;
- `unit`: platform-independent and applicable target tests;
- `artifact`: architecture/platform markers and package integrity;
- `device`: physical or simulator behavior that compilation cannot prove.

A release is not validated merely because its profile passes `config`. All applicable gates must be recorded by the release workflow.

The current Windows and Linux release wrappers are explicitly x86_64-only. An ARM64 desktop build must add a separate profile and matching native dependency/package paths before those wrappers accept it.
