# Open follow-ups outside `re/`

Changes this directory cannot make. Each item says what to change and why.

## Sources

- `Sources/FS2Core/Machine/Machine.swift`: the section heading "Development bridge to
  not-yet-ported routines" and the doc comment of `originalBridge` still speak of routines not
  ported yet; every routine is ported and no `callOriginal` call is left in `Sources`
  (`ShippingCodeTests`). Describe it as what it is now: a test-only way to run an original
  routine on the port's memory (`Render3DFrameTests`), and a tripwire for the replay matrix.
- Doc comments with the "-wards" forms the docs have dropped for the American ones (afterward,
  leftward, rightward, upward, downward), in `Sources/FS2App` and `Sources/FS2Core`
  (`grep -rnwE 'afterwards|leftwards|rightwards|upwards|downwards' Sources`).

## Makefile

- `AUDIT_SUITES` runs `CrackExclusionTests` and `SubLogicBytesAuditTests` (which includes the
  instruction-listing check); adding `ShippingCodeTests` would put every shipping audit
  (`excluded.md`, The audits) into `make audit`.

## Lab tooling (requested in `coverage.md`)

- `fs2lab coverage-report <dir>`: the coverage analysis as a lab command reading the `.cov` files
  and the symbol database, so `coverage.md` can be regenerated.
- A `--chargen <rom>` option for `fs2lab run`, so editor screenshots render
  (`GameData(d64URL:charROMURL:)` already supports it; the headless app has `--charrom`).
