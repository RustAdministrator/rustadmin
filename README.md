# RustAdmin

**RustAdmin** is an experimental fork of [RustDesk](https://github.com/rustdesk/rustdesk) focused on self-hosted remote administration, local networks, and VPN-first deployments.

The project keeps RustDesk’s open-source foundation while exploring a stricter security posture, safer defaults, better administrative workflows, and improved desktop usability.

> [!IMPORTANT]
> This project is not affiliated with or endorsed by the RustDesk project. RustAdmin is a fork and retains upstream RustDesk components, protocol concepts, build system parts, and licensing obligations.

## Project direction

RustAdmin is aimed primarily at environments where the operator controls the network path:

* local networks
* site-to-site VPNs
* private WireGuard / OpenVPN / IPsec links
* self-hosted rendezvous and relay infrastructure
* small teams, labs, workshops, and private administration setups

The main development priorities are:

* **Security-first defaults** — reduce unsafe remote configuration changes and avoid trusting unverified network hints.
* **Self-hosting** — prefer deployments where the administrator controls rendezvous, relay, API, and access policy.
* **Local/VPN operation** — improve behavior for private address ranges and trusted internal networks.
* **Quality and maintainability** — keep changes reviewable, tested, and limited to meaningful behavior changes.
* **Usability for administrators** — improve first-run setup, connection status visibility, toolbar behavior, scaling controls, and desktop workflows.

## Misuse disclaimer

RustAdmin is remote administration software. It must only be used on systems you own, administer, or have explicit permission to access.

The developers do not condone or support unauthorized access, covert control, privacy invasion, credential theft, malware deployment, or any other unethical or illegal use. The authors are not responsible for misuse of this software.

## Current fork changes

RustAdmin currently contains upstream RustDesk code plus fork-specific work in the following areas:

* safer handling of rendezvous-provided peer address hints
* broader protection of security-sensitive remote configuration options
* relay server resolution fixes before relay creation
* first-run wizard and clearer initial setup flow
* improved network status panel layout
* toolbar auto-hide settings and toolbar behavior prototyping
* edge-acceleration scrolling and pointer tracking improvements
* custom scale presets in the desktop toolbar
* cross-platform local build wrappers for Linux, Windows, and macOS
* macOS build, entitlement, and codesigning workflow improvements

This list describes the current development direction and may change as the fork evolves.

## Recommended deployment model

For security-focused use, RustAdmin should normally be deployed with:

1. a self-hosted rendezvous/relay server,
2. access through LAN or VPN whenever possible,
3. restricted firewall exposure,
4. pinned and reviewed client configuration,
5. strong authentication and approval settings,
6. logging and monitoring appropriate for the environment.

Public internet exposure should be treated as a higher-risk deployment model and should be reviewed carefully.

## Build

RustAdmin inherits much of the RustDesk build system. The modern desktop UI is Flutter-based; the older Sciter UI is legacy/deprecated.

### Clone

```sh
git clone --recurse-submodules https://github.com/RustAdministrator/rustadmin.git
cd rustadmin
```

If the repository was cloned without submodules:

```sh
git submodule update --init --recursive
```

### Common requirements

You need a working Rust toolchain and platform build tools.

Install Rust:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
```

Install `vcpkg` dependencies:

```sh
git clone https://github.com/microsoft/vcpkg "$HOME/vcpkg"
cd "$HOME/vcpkg"
git checkout 2023.04.15
./bootstrap-vcpkg.sh
export VCPKG_ROOT="$HOME/vcpkg"
"$VCPKG_ROOT/vcpkg" install libvpx libyuv opus aom
```

On Windows, use the appropriate triplets, for example:

```powershell
vcpkg install libvpx:x64-windows-static libyuv:x64-windows-static opus:x64-windows-static aom:x64-windows-static
```

### Flutter desktop build

The fork includes platform wrappers that help avoid stale Flutter metadata when switching between Linux, Windows, and macOS from the same checkout.

Linux:

```sh
scripts/build_linux.sh
```

Windows PowerShell:

```powershell
.\scripts\build_windows.ps1
```

macOS:

```sh
scripts/build_macos.sh
```

Use the script options documented in `scripts/README.md` for custom Flutter paths, codec roots, clean builds, hardware codec toggles, and toolbar lab runs.

### Legacy Sciter build

The legacy Sciter path is kept for compatibility with upstream RustDesk, but new desktop UI work should generally target Flutter.

```sh
cargo run
```

For the legacy UI, the Sciter dynamic library may be required in the expected target directory.

## Development notes

Useful commands:

```sh
cargo test --lib -- --test-threads=1
cd flutter && flutter test
python3 build.py --flutter
python3 build.py --flutter --release
```

Some Rust client tests mutate process-wide config or inspect local system state.
Use the serial `cargo test --lib -- --test-threads=1` command for the full
client library suite; running it in parallel can produce false failures.

Hardware codec and platform-specific features may require additional SDKs, libraries, or driver components.

## Project structure

* `src/` — main Rust application code
* `src/server/` — audio, clipboard, input, video services, and network connections
* `src/client.rs` — peer connection handling
* `src/rendezvous_mediator.rs` — rendezvous and relay connection flow
* `src/platform/` — platform-specific code
* `src/ui/` — legacy Sciter UI
* `flutter/` — Flutter UI for desktop and mobile
* `flutter/lib/desktop/` — desktop UI
* `flutter/lib/mobile/` — mobile UI
* `flutter/lib/common/` — shared Flutter UI and helpers
* `libs/hbb_common/` — shared protocol, configuration, networking, protobuf, file transfer, and utility code
* `libs/scrap/` — screen capture
* `libs/enigo/` — keyboard and mouse control
* `libs/clipboard/` — cross-platform clipboard support
* `scripts/` — local platform build wrappers
* `prototyping/` — isolated UI experiments, including the toolbar lab

## Security and configuration work

This fork is actively exploring stricter behavior around remote configuration and connection hints. In particular, security-sensitive options such as rendezvous/relay/API settings, ICE/websocket/TLS fallback settings, direct access settings, trust and approval controls, whitelist options, and related values should not be casually overwritten by remote configuration.

Rendezvous-provided peer hints should be validated before use. Unsafe, loopback, link-local, multicast, or otherwise inappropriate peer addresses should be ignored or cause fallback to safer connection paths.

## Attribution

RustAdmin is based on [RustDesk](https://github.com/rustdesk/rustdesk), an AGPL-licensed open-source remote desktop project written in Rust.

Many components, design concepts, dependencies, protocol elements, and build workflows originate from RustDesk and its contributors. RustAdmin keeps this attribution and remains subject to the applicable upstream licenses.

## License

This project follows the upstream licensing model and is distributed under the AGPL-3.0 license unless otherwise noted in individual files or dependencies.

See `LICENCE` for details.

## Contributing

Contributions should follow these principles:

* keep security-sensitive changes explicit and reviewable,
* avoid broad formatting-only diffs,
* prefer tests for behavior changes,
* do not introduce unsafe defaults,
* document deployment assumptions clearly,
* keep upstream attribution intact.

Before opening large changes, consider starting with an issue or discussion describing the intended behavior and threat model.

## Screenshots

RustDesk-specific screenshots and store badges have intentionally been removed from this README. Add RustAdmin-specific screenshots only after the UI branding and behavior shown in the images match this fork.
