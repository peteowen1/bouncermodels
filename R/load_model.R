# Model Loading Functions
# =======================
# Functions for loading pre-trained cricket models from local cache or GitHub releases.
# Mirrors torpmodels pattern: download once, cache locally, load fast.

# Available models by category
# ----------------------------

#' @noRd
.BALL_OUTCOME_MODELS <- c(
  "agnostic_outcome_t20" = "Agnostic ball outcome model for T20 (context-only, no player identity)",
  "agnostic_outcome_odi" = "Agnostic ball outcome model for ODI",
  "agnostic_outcome_test" = "Agnostic ball outcome model for Test",
  "full_outcome_t20" = "Full ball outcome model for T20 (includes player/team/venue skills)",
  "full_outcome_odi" = "Full ball outcome model for ODI",
  "full_outcome_test" = "Full ball outcome model for Test"
)

#' @noRd
.PREDICTION_MODELS <- c(
  "t20_prediction_model" = "Pre-match win probability model for T20",
  "odi_prediction_model" = "Pre-match win probability model for ODI",
  "test_prediction_model" = "Pre-match win probability model for Test",
  "t20_margin_model" = "Margin prediction model for T20",
  "odi_margin_model" = "Margin prediction model for ODI",
  "test_margin_model" = "Margin prediction model for Test",
  "ipl_prediction_model" = "IPL-specific prediction model"
)

#' @noRd
.IN_MATCH_MODELS <- c(
  "odi_stage1_projected_score" = "ODI in-match projected score model",
  "odi_stage2_win_probability" = "ODI in-match win probability model",
  "test_stage1_projected_score" = "Test in-match projected score model",
  "test_win_probability" = "Test in-match win probability model",
  "test_result_model" = "Test match result prediction model",
  "test_conditional_win_model" = "Test conditional win probability model"
)

#' Get the bouncermodels repository
#' @keywords internal
get_bouncermodels_repo <- function() {
  getOption("bouncermodels.repo", "peteowen1/bouncermodels")
}

#' Get the local models directory
#'
#' Returns the path to the local models cache directory.
#'
#' @return Character string path to local models directory
#' @keywords internal
get_models_dir <- function() {
  cache_dir <- getOption("bouncermodels.cache_dir", NULL)

  if (!is.null(cache_dir)) {
    if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE)
    return(cache_dir)
  }

  cache_base <- tools::R_user_dir("bouncermodels", "cache")
  models_dir <- file.path(cache_base, "models")
  if (!dir.exists(models_dir)) dir.create(models_dir, recursive = TRUE)
  return(models_dir)
}

# Manifest-verified cache freshness (ECOSYSTEM-FIX-PLAN.md M6)
# -----------------------------------------------------------------
# bouncermodels has no manifest layer of its own (unlike torpmodels'
# models_manifest.json) -- it uses versebus's generic bus_manifest.json
# directly. `.get_bus_manifest()` wraps `vb_read_manifest()` (vendored in
# versebus.R) with a session-local, rate-limited cache (one fetch per
# (repo, tag) per 15-minute window) so a cache-hit check doesn't hit the
# network on every single load. `vb_read_manifest()` already implements the
# "exactly one legacy-mode warning per session per tag" rule internally
# (via its own `.vb_state` env) for the confirmed-absent case; what it does
# NOT do is degrade gracefully on a *transient* fetch failure -- it
# propagates those (by design, for producer callers that must not silently
# treat a network blip as "no manifest"). A read-only cache-freshness check
# must not hard-fail a load that could otherwise succeed from a good local
# cache, so that propagated error is caught here and degraded to "skip
# verification this session" instead.

#' @noRd
.bm_manifest_state <- new.env(parent = emptyenv())

#' @noRd
.bm_manifest_ttl_secs <- 900L

#' Session-cached, rate-limited fetch of a tag's bus_manifest.json
#' @keywords internal
.get_bus_manifest <- function(repo, tag, verbose = TRUE) {
  key <- paste0(repo, "@", tag)
  cached <- .bm_manifest_state[[key]]
  if (!is.null(cached) &&
      as.numeric(Sys.time() - cached$fetched_at, units = "secs") < .bm_manifest_ttl_secs) {
    return(cached$manifest)
  }

  manifest <- tryCatch(
    vb_read_manifest(repo, tag, required = FALSE),
    error = function(e) {
      if (verbose) {
        cli::cli_warn("Could not fetch bus_manifest.json for {.val {tag}} ({conditionMessage(e)}) -- skipping cache verification this session")
      }
      NULL
    }
  )
  .bm_manifest_state[[key]] <- list(manifest = manifest, fetched_at = Sys.time())
  manifest
}

#' Is a locally cached model file still valid against bus_manifest.json?
#'
#' TRUE (serve from cache) when there's no manifest to check against
#' (legacy mode) or no entry for this specific file (an untracked asset --
#' can't validate it, so don't punish it); otherwise delegates to
#' versebus's sidecar-based `vb_cache_validate()`.
#' @keywords internal
.bm_cache_is_fresh <- function(repo, tag, file_name, local_path, verbose = TRUE) {
  manifest <- .get_bus_manifest(repo, tag, verbose)
  if (is.null(manifest) || is.null(manifest$assets)) return(TRUE)
  entry <- .vb_manifest_entry_for(manifest, file_name)
  if (is.null(entry) || is.null(entry$sha256)) return(TRUE)
  vb_cache_validate(local_path, entry)
}


#' Load a Bouncer Model
#'
#' Loads a pre-trained model from local cache or downloads from GitHub releases.
#' Models are cached locally after first download for faster subsequent loads.
#'
#' @param model_name Character. Name of the model to load. See
#'   \code{\link{list_available_models}} for available models.
#' @param force_download Logical. If TRUE, downloads fresh copy even if cached.
#' @param verbose Logical. If TRUE, prints status messages.
#'
#' @return The loaded model object (typically an xgboost booster or RDS object)
#' @export
#'
#' @examples
#' \dontrun{
#' model <- load_bouncer_model("agnostic_outcome_t20")
#' pred_model <- load_bouncer_model("t20_prediction_model")
#' }
load_bouncer_model <- function(model_name, force_download = FALSE, verbose = TRUE) {
  model_name <- tolower(model_name)
  model_info <- resolve_model(model_name)

  if (is.null(model_info)) {
    all_models <- list_available_models()
    all_names <- unlist(lapply(all_models, names))
    cli::cli_abort(c(
      "Unknown model: {model_name}",
      "i" = "Available models: {paste(all_names, collapse = ', ')}",
      "i" = "See {.fn list_available_models} for details"
    ))
  }

  local_path <- file.path(get_models_dir(), model_info$tag, model_info$file)
  repo <- get_bouncermodels_repo()

  # Check local cache
  if (file.exists(local_path) && !force_download) {
    if (.bm_cache_is_fresh(repo, model_info$tag, model_info$file, local_path, verbose)) {
      if (verbose) cli::cli_inform("Loading {model_name} from local cache")
      return(load_model_file(local_path, model_name))
    }
    if (verbose) cli::cli_inform("Cached {model_name} does not match bus_manifest.json -- re-downloading")
  }

  # Download from GitHub release
  if (verbose) cli::cli_inform("Downloading {model_name} from GitHub releases...")
  download_model_from_release(model_info$file, model_info$tag, local_path, verbose)

  if (!file.exists(local_path)) {
    cli::cli_abort("Failed to download model: {model_name}")
  }

  return(load_model_file(local_path, model_name))
}


#' List Available Models
#'
#' Returns a list of all available models that can be loaded.
#'
#' @return A list with three elements: ball_outcome, prediction, in_match
#' @export
#'
#' @examples
#' list_available_models()
list_available_models <- function() {
  list(
    ball_outcome = .BALL_OUTCOME_MODELS,
    prediction = .PREDICTION_MODELS,
    in_match = .IN_MATCH_MODELS
  )
}


#' Check Model Cache Status
#'
#' Shows which models are cached locally and their file sizes.
#'
#' @return A data frame with model names, cached status, and sizes
#' @export
#'
#' @examples
#' check_model_cache()
check_model_cache <- function() {
  models_dir <- get_models_dir()

  all_models <- c(.BALL_OUTCOME_MODELS, .PREDICTION_MODELS, .IN_MATCH_MODELS)
  results <- data.frame(
    model = character(), type = character(),
    cached = logical(), size_mb = numeric(),
    stringsAsFactors = FALSE
  )

  for (model_name in names(all_models)) {
    info <- resolve_model(model_name)
    if (is.null(info)) next

    path <- file.path(models_dir, info$tag, info$file)
    cached <- file.exists(path)
    size <- if (cached) round(file.size(path) / 1024^2, 2) else NA_real_

    results <- rbind(results, data.frame(
      model = model_name, type = info$tag,
      cached = cached, size_mb = size,
      stringsAsFactors = FALSE
    ))
  }

  return(results)
}


#' Clear Model Cache
#'
#' Removes cached models from local storage.
#'
#' @param type Character. "all", "ball-outcome", "prediction", or "in-match".
#' @param verbose Logical. If TRUE, prints status messages.
#'
#' @return Invisible NULL
#' @export
#'
#' @examples
#' \dontrun{
#' clear_model_cache("all")
#' }
clear_model_cache <- function(type = "all", verbose = TRUE) {
  type <- match.arg(type, c("all", "ball-outcome", "prediction", "in-match"))
  models_dir <- get_models_dir()

  tags <- if (type == "all") c("ball-outcome", "prediction", "in-match") else type

  for (tag in tags) {
    tag_dir <- file.path(models_dir, tag)
    if (dir.exists(tag_dir)) {
      files <- list.files(tag_dir, full.names = TRUE)
      if (length(files) > 0) {
        unlink(files)
        if (verbose) cli::cli_inform("Cleared {length(files)} {tag} model(s)")
      }
    }
  }

  invisible(NULL)
}


# Internal helpers
# ----------------

#' Resolve model name to file and release tag
#' @keywords internal
resolve_model <- function(model_name) {
  model_name <- tolower(model_name)

  # Ball outcome models (.ubj format)
  if (model_name %in% names(.BALL_OUTCOME_MODELS)) {
    return(list(file = paste0(model_name, ".ubj"), tag = "ball-outcome"))
  }

  # Prediction models (.ubj format)
  if (model_name %in% names(.PREDICTION_MODELS)) {
    return(list(file = paste0(model_name, ".ubj"), tag = "prediction"))
  }

  # In-match models (.ubj format)
  if (model_name %in% names(.IN_MATCH_MODELS)) {
    return(list(file = paste0(model_name, ".ubj"), tag = "in-match"))
  }

  # Also try with .rds extension for older models
  rds_name <- sub("\\.ubj$", "", model_name)
  if (rds_name %in% names(.PREDICTION_MODELS)) {
    return(list(file = paste0(rds_name, ".ubj"), tag = "prediction"))
  }

  return(NULL)
}

#' Load a model file based on extension
#' @keywords internal
load_model_file <- function(path, label = basename(path)) {
  ext <- tools::file_ext(path)

  if (ext == "ubj") {
    if (!requireNamespace("xgboost", quietly = TRUE)) {
      cli::cli_abort(c(
        "Package {.pkg xgboost} is required to load XGBoost models.",
        "i" = "Install with: {.code install.packages('xgboost')}"
      ))
    }
    return(safe_load_ubj(path, label))
  }

  if (ext == "rds") {
    return(safe_read_rds(path, label))
  }

  cli::cli_abort("Unsupported model format: .{ext}")
}

#' Safely load an XGBoost .ubj file with error handling
#'
#' Mirrors safe_read_rds(): if the cached file is corrupt/truncated (only
#' caught here, since the size check in download_model_from_release lets
#' small-but-invalid files through), delete it so the next call re-downloads
#' instead of failing forever against the same bad cache entry.
#' @keywords internal
safe_load_ubj <- function(path, label = basename(path)) {
  tryCatch(
    xgboost::xgb.load(path),
    error = function(e) {
      msg <- conditionMessage(e)
      unlink(path)
      unlink(paste0(path, ".sha256"))
      cli::cli_abort("Model file for {label} is corrupted: {msg}. Cache cleared, try again.")
    }
  )
}

#' Safely read an RDS file with error handling
#' @keywords internal
safe_read_rds <- function(path, label = basename(path)) {
  tryCatch(
    readRDS(path),
    error = function(e) {
      msg <- conditionMessage(e)
      is_corruption <- grepl(
        "unknown input format|not an RDS file|decompression|bad restore file",
        msg, ignore.case = TRUE
      )
      if (is_corruption) {
        unlink(path)
        unlink(paste0(path, ".sha256"))
        cli::cli_abort("Model file for {label} is corrupted: {msg}. Cache cleared, try again.")
      }
      cli::cli_abort("Failed to load model {label}: {msg}")
    }
  )
}

#' Download model from GitHub release
#'
#' Verifies sha256 against `bus_manifest.json` when the tag's manifest
#' tracks this file -- replacing the old `file.size > 100` heuristic, which
#' is now only a last-resort fallback for tags/files with no manifest entry
#' to compare against (legacy mode). Each download attempt lands in a
#' tempdir created beside the destination and is moved into place
#' atomically via `vb_atomic_write()`, with a `<local_path>.sha256` sidecar
#' written alongside on success. A failed integrity check deletes the temp
#' and retries the SAME method once before falling through to the next
#' method (piggyback, then a direct release URL); a pre-existing
#' `local_path` is never touched by a failed download.
#' @keywords internal
#' @importFrom cli cli_inform cli_warn cli_abort
download_model_from_release <- function(file_name, release_tag, local_path, verbose = TRUE) {
  repo <- get_bouncermodels_repo()

  parent_dir <- dirname(local_path)
  if (!dir.exists(parent_dir)) dir.create(parent_dir, recursive = TRUE)

  manifest <- .get_bus_manifest(repo, release_tag, verbose)
  entry <- .vb_manifest_entry_for(manifest, file_name)

  # One fetch+verify+place attempt. `fetch_fn(tmpdir)` must leave `file_name`
  # inside `tmpdir`; raises a vb_error_integrity on a corrupt/undersized/
  # mismatched download, otherwise propagates whatever error the download
  # call itself raised (network, 404, ...).
  attempt <- function(fetch_fn) {
    tmpdir <- tempfile(".bm_dl_", tmpdir = parent_dir)
    dir.create(tmpdir)
    on.exit(unlink(tmpdir, recursive = TRUE), add = TRUE)

    fetch_fn(tmpdir)

    tmp <- file.path(tmpdir, file_name)
    if (!file.exists(tmp) || file.size(tmp) == 0L) {
      .vb_abort("{file_name}: download produced no/empty file", "vb_error_integrity")
    }
    if (!is.null(entry) && !is.null(entry$sha256)) {
      got <- vb_sha256(tmp)
      if (!identical(got, entry$sha256)) {
        .vb_abort(
          "{file_name}: sha256 mismatch vs bus_manifest.json (got {substr(got, 1, 12)}..., want {substr(entry$sha256, 1, 12)}...)",
          "vb_error_integrity"
        )
      }
    } else if (file.size(tmp) <= 100L) {
      # No manifest entry to verify against -- legacy size heuristic.
      .vb_abort("{file_name}: downloaded file is too small (likely an error page)", "vb_error_integrity")
    }

    vb_atomic_write(function(p) file.copy(tmp, p, overwrite = TRUE), local_path)
    writeLines(vb_sha256(local_path), paste0(local_path, ".sha256"))
    invisible(TRUE)
  }

  with_retry <- function(fetch_fn, label) {
    result <- tryCatch(attempt(fetch_fn), error = function(e) e)
    if (inherits(result, "vb_error_integrity")) {
      if (verbose) {
        cli::cli_warn("{label} download of {file_name} failed integrity check ({conditionMessage(result)}); retrying once")
      }
      result <- tryCatch(attempt(fetch_fn), error = function(e) e)
    }
    result
  }

  # Try piggyback first (preferred method)
  pb_result <- with_retry(function(tmpdir) {
    piggyback::pb_download(file = file_name, repo = repo, tag = release_tag,
                           dest = tmpdir, overwrite = TRUE)
  }, "piggyback")

  if (!inherits(pb_result, "error")) {
    if (verbose) cli::cli_inform("Downloaded {file_name}")
    return(invisible(TRUE))
  }
  if (verbose) cli::cli_warn("piggyback download failed: {conditionMessage(pb_result)}")

  # Fallback to direct URL
  url_result <- with_retry(function(tmpdir) {
    url <- paste0("https://github.com/", repo, "/releases/download/", release_tag, "/", file_name)
    if (verbose) cli::cli_inform("Trying direct download from {url}")
    # Qualified on purpose (not an unqualified `@importFrom` binding): a bare
    # `download.file()` resolves to the copy captured in this package's
    # namespace at load time, which testthat's
    # `local_mocked_bindings(.package = "utils")` cannot reach -- only a
    # live `utils::` lookup sees the mocked binding.
    utils::download.file(url, file.path(tmpdir, file_name), mode = "wb", quiet = !verbose)
  }, "direct URL")

  if (!inherits(url_result, "error")) {
    if (verbose) cli::cli_inform("Downloaded {file_name}")
    return(invisible(TRUE))
  }

  # Both methods failed -- report both; type as vb_error_integrity if either
  # failure was a corruption signal (never silently downgrade that to a
  # generic error).
  details <- paste0(
    "piggyback: ", conditionMessage(pb_result), "; ",
    "direct URL: ", conditionMessage(url_result)
  )
  is_integrity <- inherits(pb_result, "vb_error_integrity") || inherits(url_result, "vb_error_integrity")
  cli::cli_abort(
    "Failed to download {file_name} from release {release_tag}. {details}",
    class = if (is_integrity) c("vb_error_integrity", "vb_error") else "vb_error"
  )
}
