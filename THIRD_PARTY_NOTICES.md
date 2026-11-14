# Third-Party Notices

This project embeds an unofficial HarmonyOS Tailscale engine. It is not
affiliated with, endorsed by, or sponsored by Tailscale Inc.

When distributing a HAP or any other binary that contains the libraries below,
ship this file together with the `licenses/` directory.

## Bundled binaries

| File | Contents |
|---|---|
| `harmony-app/entry/libs/arm64-v8a/libtailscale_go.so` | Tailscale 1.104.5, Go runtime, and Tailscale's Go dependencies |
| `harmony-app/entry/libs/arm64-v8a/libc++_shared.so` | LLVM libc++ (byte-identical to the copy in the MeshArc prebuilt HAP, SHA-256 `e18522ffe1a721673e5b1fa0b05731b0214958a4dd697a227502085a9217079f`) |

## Tailscale

Copyright (c) 2020 Tailscale Inc & contributors.
Licensed under the BSD 3-Clause License.
Full text: [`licenses/Tailscale-BSD-3-Clause.txt`](licenses/Tailscale-BSD-3-Clause.txt)

`libtailscale_go.so` also contains third-party Go modules. Tailscale publishes a
generated dependency inventory with the exact version and license link for each
module:

- [`licenses/Tailscale-1.104.5-dependencies.md`](licenses/Tailscale-1.104.5-dependencies.md)

That inventory is generated for the upstream `tailscale`/`tailscaled` commands
and is therefore a superset of what this embedded build may contain. The license
families referenced by it are reproduced in `licenses/`:

- BSD-3-Clause: see the Tailscale, MeshArc and Go license files
- `licenses/BSD-2-Clause.txt`
- `licenses/MIT.txt`
- `licenses/Apache-2.0.txt`
- `licenses/ISC.txt`

## Go runtime / go-ohos

Copyright 2009 The Go Authors.
Licensed under the BSD 3-Clause License.
Full text: [`licenses/Go-BSD-3-Clause.txt`](licenses/Go-BSD-3-Clause.txt)
Go patent grant: [`licenses/Go-PATENTS.txt`](licenses/Go-PATENTS.txt)

The OpenHarmony port is carried forward from the OpenHarmony SIG Go port and
MeshArc engineering work. Source: https://github.com/flypigJ/go-ohos

## MeshArc / Tailscale-OHOS / tailscale-ohos-core

Copyright (c) 2026, Jerry Zhu and MeshArc contributors.
Licensed under the BSD 3-Clause License.
Full text: [`licenses/MeshArc-BSD-3-Clause.txt`](licenses/MeshArc-BSD-3-Clause.txt)
Sources:
- https://github.com/flypigJ/Tailscale-OHOS
- https://github.com/flypigJ/tailscale-ohos-core

The bridge/lifecycle code and the 1.104.5 OpenHarmony platform patch are
derived from these projects. They are not claimed as official Tailscale work.

## libc++ (libc++_shared.so)

`libc++_shared.so` is part of the LLVM Project and is licensed under the
Apache License v2.0 with LLVM Exceptions.
Copyright (c) 2009-2026 LLVM Project contributors and Apple Inc.
Full text: [`licenses/LLVM-Apache-2.0-with-LLVM-exception.txt`](licenses/LLVM-Apache-2.0-with-LLVM-exception.txt)

The bundled copy was taken from the MeshArc prebuilt HAP; its SHA-256 is recorded
above so the exact artifact can be identified.

## HarmonyOS SDK

The HarmonyOS/OpenHarmony SDK, DevEco Studio, and signing tools are build-time
inputs and are not redistributed by this repository. Their use is governed by
Huawei's terms.

## Notes

- The dependency inventory above lists license links to pinned upstream
  versions. For a formal product distribution, retain the corresponding
  upstream copyright notices alongside this file.
- This document is not legal advice.
