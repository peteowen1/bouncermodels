# upload_models.R
# Upload existing model files from bouncerdata/models/ to bouncermodels releases.
# Run once to populate the releases, then ad-hoc after retraining.
#
# Usage: Rscript data-raw/upload_models.R

library(piggyback)
library(cli)

REPO <- "peteowen1/bouncermodels"
MODELS_DIR <- "C:/Users/peteo/OneDrive/Documents/bouncerverse/bouncerdata/models"

cli_h1("Upload Models to bouncermodels")

if (!dir.exists(MODELS_DIR)) cli_abort("Models directory not found: {MODELS_DIR}")

# Define release tags and which models go where
releases <- list(
  "ball-outcome" = c(
    "agnostic_outcome_t20.ubj",
    "agnostic_outcome_odi.ubj",
    "agnostic_outcome_test.ubj",
    "full_outcome_t20.ubj",
    "full_outcome_odi.ubj",
    "full_outcome_test.ubj"
  ),
  "prediction" = c(
    "t20_prediction_model.ubj",
    "odi_prediction_model.ubj",
    "test_prediction_model.ubj",
    "t20_margin_model.ubj",
    "odi_margin_model.ubj",
    "test_margin_model.ubj",
    "ipl_prediction_model.ubj",
    "t20_prediction_features.rds",
    "odi_prediction_features.rds",
    "test_prediction_features.rds"
  ),
  "in-match" = c(
    "odi_stage1_projected_score.ubj",
    "odi_stage2_win_probability.ubj",
    "test_stage1_projected_score.ubj",
    "test_win_probability.ubj",
    "test_result_model.ubj",
    "test_conditional_win_model.ubj"
  )
)

for (tag in names(releases)) {
  cli_h2("Release: {tag}")

  tryCatch(
    pb_release_create(repo = REPO, tag = tag, name = paste("Bouncer", tag, "models")),
    error = function(e) cli_alert_info("Release '{tag}' already exists")
  )

  files <- releases[[tag]]
  for (f in files) {
    path <- file.path(MODELS_DIR, f)
    if (file.exists(path)) {
      tryCatch({
        pb_upload(path, repo = REPO, tag = tag, overwrite = TRUE)
        size_mb <- round(file.size(path) / 1024 / 1024, 1)
        cli_alert_success("{f} ({size_mb} MB)")
      }, error = function(e) {
        cli_alert_danger("Failed to upload {f}: {e$message}")
      })
    } else {
      cli_alert_warning("Not found: {f}")
    }
  }
}

cli_h1("Upload Complete")
cli_alert_info("Models are now available via: devtools::install_github('peteowen1/bouncermodels')")
