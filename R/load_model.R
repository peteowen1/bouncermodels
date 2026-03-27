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

  # Check local cache
  if (file.exists(local_path) && !force_download) {
    if (verbose) cli::cli_inform("Loading {model_name} from local cache")
    return(load_model_file(local_path, model_name))
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
    return(xgboost::xgb.load(path))
  }

  if (ext == "rds") {
    return(safe_read_rds(path, label))
  }

  cli::cli_abort("Unsupported model format: .{ext}")
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
        cli::cli_abort("Model file for {label} is corrupted: {msg}. Cache cleared, try again.")
      }
      cli::cli_abort("Failed to load model {label}: {msg}")
    }
  )
}

#' Download model from GitHub release
#' @keywords internal
#' @importFrom cli cli_inform cli_warn cli_abort
#' @importFrom utils download.file
download_model_from_release <- function(file_name, release_tag, local_path, verbose = TRUE) {
  repo <- get_bouncermodels_repo()

  parent_dir <- dirname(local_path)
  if (!dir.exists(parent_dir)) dir.create(parent_dir, recursive = TRUE)

  # Try piggyback first
  tryCatch({
    temp_dir <- tempdir()
    piggyback::pb_download(file = file_name, repo = repo, tag = release_tag, dest = temp_dir)
    temp_path <- file.path(temp_dir, file_name)

    if (file.exists(temp_path) && file.size(temp_path) > 100) {
      file.copy(temp_path, local_path, overwrite = TRUE)
      unlink(temp_path)
      if (verbose) cli::cli_inform("Downloaded {file_name}")
      return(invisible(TRUE))
    }
    stop("File not found or too small after download")
  }, error = function(e) {
    if (verbose) cli::cli_warn("piggyback download failed: {e$message}")
  })

  # Fallback to direct URL
  tryCatch({
    url <- paste0("https://github.com/", repo, "/releases/download/", release_tag, "/", file_name)
    if (verbose) cli::cli_inform("Trying direct download...")
    download.file(url, local_path, mode = "wb", quiet = !verbose)
    if (file.exists(local_path) && file.size(local_path) > 100) {
      if (verbose) cli::cli_inform("Downloaded {file_name}")
      return(invisible(TRUE))
    }
  }, error = function(e) {
    cli::cli_warn("Direct download failed: {e$message}")
  })

  cli::cli_abort("Failed to download {file_name} from release {release_tag}")
}
