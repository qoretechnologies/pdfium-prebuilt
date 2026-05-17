# pdfium-prebuilt

Prebuilt PDFium binaries for Qore CI and Qorus builds.

This repository builds PDFium from a pinned commit and publishes release assets
for the current CI base images:

- `linux/amd64` (Ubuntu resolute build)
- `linux/arm64` (Ubuntu resolute build)
- `linux/amd64` (Alpine 3.23 build)
- `linux/arm64` (Alpine 3.23 build)

Artifacts are published as GitHub Releases and consumed by `qore-test-base`,
`module-pdf`, and Qorus builds.

## Release strategy

PDFium does not publish official releases. We follow Chromium stable milestones:

1) Identify the current Chromium stable milestone (M*).
2) Find the PDFium commit corresponding to that milestone.
3) Pin `PDFIUM_REF` to that commit.
4) Publish a release tagged like `M<milestone>-YYYY-MM-DD`.

See `docs/STABLE_UPDATE.md` for the exact update procedure.

## Building locally

```bash
./scripts/build_pdfium.sh \
  --pdfium-ref <commit> \
  --target-os ubuntu \
  --arch amd64

./scripts/package_pdfium.sh \
  --pdfium-src ./build/pdfium \
  --pdfium-out ./build/pdfium/out/Release \
  --target-os ubuntu \
  --arch amd64 \
  --pdfium-ref <commit> \
  --target-image ubuntu:resolute \
  --chromium-milestone M148
```

## Using artifacts

Artifacts are published as `pdfium-<commit>-<target_os>-<arch>.tar.xz` and
include:

- `include/` headers
- `lib/libpdfium.so` and/or `lib/libpdfium.a`
- `VERSION` metadata
- `LICENSES/` for PDFium and third-party notices

Example download:

```bash
curl -L -o pdfium.tar.xz \
  "https://github.com/qoretechnologies/pdfium-prebuilt/releases/download/M148-2026-05-17/pdfium-<commit>-ubuntu-amd64.tar.xz"
tar -xf pdfium.tar.xz
```

## Tests

Run the script-level tests:

```bash
./tests/run.sh
```

## License

MIT License for repository scripts and config. PDFium itself is BSD-3-Clause;
release artifacts include PDFium and third-party licenses.

## Copyright

Copyright 2026 Qore Technologies, s.r.o.
