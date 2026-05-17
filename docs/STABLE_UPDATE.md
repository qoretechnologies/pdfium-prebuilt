# PDFium stable update process

PDFium does not publish official releases. We align to Chromium stable
milestones and pin to a specific PDFium commit.

## Identify the stable milestone

1) Find the current Chromium stable milestone (M*).
2) Determine the matching PDFium commit for that milestone.

We record both in release metadata.

## Suggested tagging scheme

Tag format: `M<milestone>-YYYY-MM-DD`

Examples:
- `M126-2026-01-15`
- `M127-2026-02-14`

## Update steps

1) Pick the PDFium commit:
   - Record it as `PDFIUM_REF`.
2) Run the GitHub Actions workflow with inputs:
   - `pdfium_ref`: the commit hash
   - `chromium_milestone`: `M*`
3) Verify release assets exist for:
   - Ubuntu resolute: `ubuntu/amd64`, `ubuntu/arm64`
   - Alpine 3.23: `alpine/amd64`, `alpine/arm64`
4) Update consumers:
   - `qore-test-base` Docker images
   - Qorus builds

## Rollback

If a milestone fails, re-run the workflow using the previous known-good
`PDFIUM_REF` and tag a new release with a corrected date suffix.

## Copyright

Copyright 2026 Qore Technologies, s.r.o.
