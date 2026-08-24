# Regression tests for the manifest-verified model cache (ECOSYSTEM-FIX-PLAN.md
# M6: cache-hit freshness vs bus_manifest.json, verified/atomic downloads;
# M7: safe_load_ubj() self-heal deletes the sha256 sidecar too). All
# piggyback/gh/utils network calls are mocked -- no network.
#
# Like pannamodels (and unlike torpmodels' own models_manifest.json
# fetcher), bouncermodels uses versebus's generic vb_read_manifest()/
# vb_list_assets() directly, so both `gh::gh` (release asset listing) and
# `piggyback::pb_download` (both for bus_manifest.json itself and for model
# files) need mocking -- dispatch on the `file`/`name` argument.
#
# Every bouncermodels model is served as `.ubj` (resolve_model() always
# returns a `.ubj` file), so tests that exercise a full successful
# load_bouncer_model() round trip need real, loadable xgboost content --
# built once here from a trivial 4-row fixture and reused as raw bytes
# (cheap: max_depth = 1, nrounds = 1) rather than retrained per test.

skip_if_not_installed("xgboost")

.fixture_ubj_bytes <- local({
  tmp <- tempfile(fileext = ".ubj")
  on.exit(unlink(tmp))
  dm <- xgboost::xgb.DMatrix(matrix(c(0, 1, 1, 0, 1, 0, 0, 1), ncol = 2),
                             label = c(0, 1, 1, 0))
  booster <- xgboost::xgb.train(
    params = list(objective = "binary:logistic", max_depth = 1, verbosity = 0),
    data = dm, nrounds = 1
  )
  xgboost::xgb.save(booster, tmp)
  readBin(tmp, "raw", file.size(tmp))
})

write_fixture_ubj <- function(path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeBin(.fixture_ubj_bytes, path)
  invisible(path)
}

make_fake_bus_manifest <- function(tag = "ball-outcome", assets = list()) {
  list(
    schema_version = 1L,
    tag = tag,
    generation = "20260711T000000Z-l000000",
    produced_at_utc = "2026-07-11T00:00:00Z",
    producer = list(repo = "test/fixture", workflow = "test", run_id = "", run_attempt = ""),
    assets = assets,
    notes = ""
  )
}

# A release asset listing that DOES include bus_manifest.json (so
# vb_list_assets/vb_read_manifest will go on to download it).
fake_release_with_manifest <- list(assets = list(
  list(name = "bus_manifest.json", size = 500, updated_at = "2026-07-11T00:00:00Z", id = 1)
))

# A release asset listing with NO bus_manifest.json -- legacy mode.
fake_release_no_manifest <- list(assets = list(
  list(name = "agnostic_outcome_t20.ubj", size = 12345, updated_at = "2026-07-11T00:00:00Z", id = 2)
))

reset_manifest_state <- function() {
  rm(list = ls(envir = bouncermodels:::.bm_manifest_state, all.names = TRUE),
     envir = bouncermodels:::.bm_manifest_state)
  rm(list = ls(envir = bouncermodels:::.vb_state, all.names = TRUE),
     envir = bouncermodels:::.vb_state)
}

# Reset both the package's own manifest-fetch cache AND versebus's
# legacy-warning state before AND after each test (withr::defer) -- these
# are session-level envs shared across every test file, so a leftover
# cached/warned entry from one test must never leak into another.
local_reset_manifest_state <- function(env = parent.frame()) {
  reset_manifest_state()
  withr::defer(reset_manifest_state(), envir = env)
}

local_model_cache_dir <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(bouncermodels.cache_dir = dir), .local_envir = env)
  dir
}

test_that("a stale cache (sha256 sidecar mismatch vs bus_manifest.json) triggers re-download", {
  local_reset_manifest_state()
  cache_dir <- local_model_cache_dir()
  outcome_dir <- file.path(cache_dir, "ball-outcome")
  dir.create(outcome_dir, recursive = TRUE)
  local_path <- file.path(outcome_dir, "agnostic_outcome_t20.ubj")
  writeLines("stale-not-a-real-model", local_path)  # never loaded -- cache is stale
  writeLines(strrep("0", 64), paste0(local_path, ".sha256"))  # deliberately wrong sha

  src_dir <- withr::local_tempdir()
  fresh_path <- file.path(src_dir, "agnostic_outcome_t20.ubj")
  write_fixture_ubj(fresh_path)
  fresh_sha <- vb_sha256(fresh_path)

  manifest <- make_fake_bus_manifest(assets = list(
    list(name = "agnostic_outcome_t20.ubj", sha256 = fresh_sha, bytes = file.size(fresh_path), rows = NA_integer_)
  ))

  gh_calls <- 0L
  testthat::local_mocked_bindings(
    gh = function(...) { gh_calls <<- gh_calls + 1L; fake_release_with_manifest },
    .package = "gh"
  )
  manifest_dl_calls <- 0L
  model_dl_calls <- 0L
  testthat::local_mocked_bindings(
    pb_download = function(file, dest, repo, tag, overwrite = TRUE, ...) {
      if (identical(file, "bus_manifest.json")) {
        manifest_dl_calls <<- manifest_dl_calls + 1L
        jsonlite::write_json(manifest, file.path(dest, file), auto_unbox = TRUE, null = "null")
      } else {
        model_dl_calls <<- model_dl_calls + 1L
        file.copy(fresh_path, file.path(dest, file))
      }
      invisible(NULL)
    },
    .package = "piggyback"
  )

  result <- load_bouncer_model("agnostic_outcome_t20", verbose = FALSE)
  expect_s3_class(result, "xgb.Booster")
  expect_identical(model_dl_calls, 1L)
  expect_identical(manifest_dl_calls, 1L)
  expect_identical(gh_calls, 1L)
  expect_identical(readLines(paste0(local_path, ".sha256")), fresh_sha)

  # A second load within the 15-minute TTL window must not re-fetch the
  # manifest (session-cached), and the now-fresh cache must not re-download.
  result2 <- load_bouncer_model("agnostic_outcome_t20", verbose = FALSE)
  expect_s3_class(result2, "xgb.Booster")
  expect_identical(gh_calls, 1L)
  expect_identical(model_dl_calls, 1L)
})

test_that("a corrupt download that would pass the old size-only heuristic raises vb_error_integrity, is deleted, and is retried once", {
  local_reset_manifest_state()
  cache_dir <- local_model_cache_dir()
  local_path <- file.path(cache_dir, "ball-outcome", "agnostic_outcome_t20.ubj")

  manifest <- make_fake_bus_manifest(assets = list(
    list(name = "agnostic_outcome_t20.ubj", sha256 = strrep("a", 64), bytes = 2000, rows = NA_integer_)
  ))

  testthat::local_mocked_bindings(
    gh = function(...) fake_release_with_manifest, .package = "gh"
  )
  pb_calls <- 0L
  testthat::local_mocked_bindings(
    pb_download = function(file, dest, repo, tag, overwrite = TRUE, ...) {
      if (identical(file, "bus_manifest.json")) {
        jsonlite::write_json(manifest, file.path(dest, file), auto_unbox = TRUE, null = "null")
      } else {
        pb_calls <<- pb_calls + 1L
        # 2000 bytes comfortably clears the OLD `file.size > 100` heuristic --
        # only the new sha256-vs-manifest check catches this as corrupt.
        writeLines(strrep("x", 2000), file.path(dest, file))
      }
      invisible(NULL)
    },
    .package = "piggyback"
  )
  url_calls <- 0L
  testthat::local_mocked_bindings(
    download.file = function(url, destfile, ...) {
      url_calls <<- url_calls + 1L
      writeLines(strrep("y", 2000), destfile)
      0L
    },
    .package = "utils"
  )

  expect_error(
    load_bouncer_model("agnostic_outcome_t20", verbose = FALSE),
    class = "vb_error_integrity"
  )
  expect_false(file.exists(local_path))
  expect_false(file.exists(paste0(local_path, ".sha256")))
  # retry invoked: the original attempt plus one retry, per download method
  expect_identical(pb_calls, 2L)
  expect_identical(url_calls, 2L)
})

test_that("a mid-download failure never leaves a partial file at the cache path", {
  local_reset_manifest_state()
  cache_dir <- local_model_cache_dir()
  local_path <- file.path(cache_dir, "ball-outcome", "agnostic_outcome_t20.ubj")

  # No bus_manifest.json on this tag -- legacy mode, nothing to verify sha256
  # against. The failure here is a mid-transfer error, not an integrity one.
  testthat::local_mocked_bindings(
    gh = function(...) fake_release_no_manifest, .package = "gh"
  )
  testthat::local_mocked_bindings(
    pb_download = function(file, dest, repo, tag, overwrite = TRUE, ...) {
      writeLines("PARTIAL-GARBAGE", file.path(dest, file))
      stop("connection reset by peer")
    },
    .package = "piggyback"
  )
  testthat::local_mocked_bindings(
    download.file = function(url, destfile, ...) {
      writeLines("PARTIAL-GARBAGE-2", destfile)
      stop("transfer closed with outstanding read data remaining")
    },
    .package = "utils"
  )

  expect_error(load_bouncer_model("agnostic_outcome_t20", verbose = FALSE))
  expect_false(file.exists(local_path))
  expect_false(file.exists(paste0(local_path, ".sha256")))
  # the per-attempt tempdirs (created beside the destination) must not leak
  outcome_dir <- dirname(local_path)
  leftovers <- if (dir.exists(outcome_dir)) list.files(outcome_dir, pattern = "^\\.bm_dl_", all.files = TRUE) else character(0)
  expect_length(leftovers, 0)
})

test_that("legacy mode (tag has no bus_manifest.json) loads from cache with exactly one session-wide warning", {
  local_reset_manifest_state()
  cache_dir <- local_model_cache_dir()
  outcome_dir <- file.path(cache_dir, "ball-outcome")
  local_path <- file.path(outcome_dir, "agnostic_outcome_t20.ubj")
  write_fixture_ubj(local_path)
  # no .sha256 sidecar -- nothing to compare against in legacy mode anyway

  gh_calls <- 0L
  testthat::local_mocked_bindings(
    gh = function(...) { gh_calls <<- gh_calls + 1L; fake_release_no_manifest },
    .package = "gh"
  )
  pb_calls <- 0L
  testthat::local_mocked_bindings(
    pb_download = function(file, dest, repo, tag, overwrite = TRUE, ...) {
      pb_calls <<- pb_calls + 1L
      stop("should never be called -- cache hit in legacy mode")
    },
    .package = "piggyback"
  )

  warnings_seen <- testthat::capture_warnings({
    result1 <- load_bouncer_model("agnostic_outcome_t20", verbose = TRUE)
    result2 <- load_bouncer_model("agnostic_outcome_t20", verbose = TRUE)
  })

  expect_s3_class(result1, "xgb.Booster")
  expect_s3_class(result2, "xgb.Booster")
  expect_length(warnings_seen, 1)
  expect_true(any(grepl("bus_manifest.json", warnings_seen, fixed = TRUE)))
  # one asset-listing call (404-free, just no bus_manifest.json in it),
  # cached for the rest of the session; the model file itself is never
  # re-downloaded -- both calls were legacy-mode cache hits
  expect_identical(gh_calls, 1L)
  expect_identical(pb_calls, 0L)
})

test_that("safe_load_ubj() self-heal deletes the cached .ubj AND its .sha256 sidecar on a corrupt file (M7)", {
  tmp <- tempfile(fileext = ".ubj")
  on.exit(unlink(c(tmp, paste0(tmp, ".sha256"))), add = TRUE)
  # Enough bytes to pass the old download-size check but not a valid
  # XGBoost model -- simulates a truncated/corrupt cached download that a
  # sha256 mismatch didn't catch (e.g. a legacy-mode tag with no manifest).
  writeBin(as.raw(sample(0:255, 200, replace = TRUE)), tmp)
  writeLines(strrep("a", 64), paste0(tmp, ".sha256"))

  expect_true(file.exists(tmp))
  expect_true(file.exists(paste0(tmp, ".sha256")))
  expect_error(safe_load_ubj(tmp, "test_model"), "corrupted")
  expect_false(file.exists(tmp))
  expect_false(file.exists(paste0(tmp, ".sha256")))
})

test_that("safe_read_rds() deletes the .sha256 sidecar alongside a corrupted cache file", {
  withr::with_tempdir({
    path <- file.path(getwd(), "corrupt.rds")
    writeLines("not an rds file", path)
    writeLines(strrep("a", 64), paste0(path, ".sha256"))
    expect_error(bouncermodels:::safe_read_rds(path, "broken_model"), "corrupted")
    expect_false(file.exists(path))
    expect_false(file.exists(paste0(path, ".sha256")))
  })
})
