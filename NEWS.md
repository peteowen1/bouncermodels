# bouncermodels (development version)

## Bug fixes

* **`versebus.R`: five silent-failure defects ported from torp's canonical
  copy (`torpverse/torp@` versebus fix, `VERSEBUS_VERSION` 1.1.0; this repo
  was still carrying all five).** All five turned a transient failure into a
  silently-accepted "everything is fine":
  * `vb_read_manifest()`'s retry-once branch classified every error as
    "confirmed absent" instead of reusing `vb_classify_error()` like the
    first attempt does. A network blip on the retry looked identical to the
    manifest genuinely having been deleted, fell through to legacy mode, and
    **disabled sha256 verification for every download on that tag for the
    rest of the session** behind a one-time warning nobody would connect to
    the cause.
  * `vb_download()`'s `verify_by_size()` swallowed a failed asset listing and
    skipped the check entirely with no warning. This is the *only* integrity
    check on an unmanifested tag -- the common case -- so a transient API
    failure meant the file was moved into place and given a `.sha256`
    sidecar as though verification had passed, with nothing recording that
    it hadn't. The fallback itself is deliberate and unchanged (aborting on
    a listing blip would brick the asset -- this exact regression shipped in
    `bouncerverse/bouncer` and was reverted in `5edd3ac`, 2026-08-16); only
    the silence is fixed.
  * `vb_publish()`'s cache-invalidation hook failed via bare
    `try(..., silent = TRUE)` -- the only failure path in this file with no
    logging at all. A dead hook meant downstream consumers kept serving
    pre-publish data indefinitely with nothing recording why.
  * `vb_publish()` also leaked `Sys.setenv(piggyback_cache_duration = 1)` for
    the rest of the R session instead of restoring the prior value on exit,
    silently disabling piggyback's listing cache for every unrelated caller
    after the first publish.
  * `vb_generation()` ran `max()` on `updated_at` with no `na.rm`. One
    unrelated asset missing a timestamp (which `vb_list_assets()`
    deliberately tolerates as `NA` rather than failing the whole listing)
    silently turned the entire generation into `NA`, indistinguishable from
    "no assets at all".

  Each has a dedicated regression test in `tests/testthat/test-versebus.R`,
  mutation-tested by reverting the fix and confirming the test fails, then
  restoring it and confirming the test passes again.
* **`versebus.R` → `VERSEBUS_VERSION` 1.1.0**, matching torp's canonical
  copy, including `.vb_generation_stamp()` switching its local-entropy
  fallback from `sample()` to `basename(tempfile(""))` so publishing no
  longer advances the caller's RNG stream.
* `tests/testthat/test-versebus-sync.R` (the drift guard against torp's
  canonical copy) now passes -- all 23 shared functions are byte-identical
  (by deparsed body) to `torpverse/torp/R/versebus.R`.
