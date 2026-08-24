# Tests for model resolution and loading (R/load_model.R)

test_that("resolve_model resolves known ball-outcome model", {
  info <- resolve_model("agnostic_outcome_t20")
  expect_equal(info$file, "agnostic_outcome_t20.ubj")
  expect_equal(info$tag, "ball-outcome")
})

test_that("resolve_model resolves known prediction and in-match models", {
  pred_info <- resolve_model("t20_prediction_model")
  expect_equal(pred_info$tag, "prediction")

  in_match_info <- resolve_model("odi_stage1_results")
  expect_equal(in_match_info$tag, "in-match")
  expect_equal(in_match_info$file, "odi_stage1_results.rds")
})

test_that("resolve_model is case-insensitive", {
  info <- resolve_model("AGNOSTIC_OUTCOME_T20")
  expect_equal(info$file, "agnostic_outcome_t20.ubj")
})

test_that("resolve_model returns NULL for unknown model", {
  expect_null(resolve_model("not_a_real_model"))
})

test_that("get_models_dir creates and returns an existing directory", {
  dir <- get_models_dir()
  expect_true(dir.exists(dir))
})

test_that("safe_load_ubj clears the cache and errors on a corrupt file", {
  skip_if_not_installed("xgboost")

  tmp <- tempfile(fileext = ".ubj")
  on.exit(unlink(tmp), add = TRUE)
  # Enough bytes to pass the download size check (>100 bytes) but not a
  # valid XGBoost model - simulates a truncated/corrupt cached download.
  writeBin(as.raw(sample(0:255, 200, replace = TRUE)), tmp)

  expect_true(file.exists(tmp))
  expect_error(safe_load_ubj(tmp, "test_model"), "corrupted")
  expect_false(file.exists(tmp))
})

test_that("clean_condition_message survives invalid bytes and multi-line traces", {
  # The CI failure this guards: xgboost's error text for a corrupt .ubj carries
  # bytes that are invalid in the session encoding, and cli's inline formatting
  # calls grepl()/gsub() on the interpolated value -- which errors, so the
  # "corrupted" abort never reached the caller.
  bad <- rawToChar(as.raw(c(0x62, 0x61, 0x64, 0x20, 0x98, 0x20, 0x62, 0x79, 0x74, 0x65)))
  cleaned <- clean_condition_message(bad)
  expect_true(validUTF8(cleaned))
  expect_no_error(cli::cli_text("{cleaned}"))

  expect_identical(clean_condition_message("first\nsecond\nthird"), "first")
  expect_identical(clean_condition_message(""), "unknown error")
  expect_identical(clean_condition_message(character(0)), "unknown error")
  expect_lte(nchar(clean_condition_message(strrep("x", 500))), 203L)
})

test_that("safe_read_rds clears the cache and errors on a corrupt file", {
  tmp <- tempfile(fileext = ".rds")
  on.exit(unlink(tmp), add = TRUE)
  writeLines("not an rds file", tmp)

  expect_true(file.exists(tmp))
  expect_error(safe_read_rds(tmp, "test_model"), "corrupted")
  expect_false(file.exists(tmp))
})
