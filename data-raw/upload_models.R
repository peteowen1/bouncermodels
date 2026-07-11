# upload_models.R
# Upload existing model files from bouncerdata/models/ to bouncermodels releases.
# Run once to populate the releases, then ad-hoc after retraining.
#
# ECOSYSTEM-FIX-PLAN.md M6: routed through vb_publish() (vendored in
# R/versebus.R) instead of a plain pb_upload(..., overwrite = TRUE) loop --
# hash-first, bounded-retry upload, post-upload verify against the live
# asset list, then bus_manifest.json uploaded LAST and only if every file in
# the tag succeeded. A failed upload aborts before the manifest, so
# consumers (`.get_bus_manifest()` / `.bm_cache_is_fresh()` in
# R/load_model.R) keep seeing the last consistent tag snapshot instead of a
# torn one.
#
# Usage: Rscript data-raw/upload_models.R

devtools::load_all(".")
library(cli)

REPO <- "peteowen1/bouncermodels"
MODELS_DIR <- "C:/dev/bouncerverse/bouncerdata/models"

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
    piggyback::pb_release_create(repo = REPO, tag = tag, name = paste("Bouncer", tag, "models")),
    error = function(e) cli_alert_info("Release '{tag}' already exists")
  )

  files <- releases[[tag]]
  paths <- file.path(MODELS_DIR, files)
  present <- paths[file.exists(paths)]
  missing <- paths[!file.exists(paths)]
  for (m in missing) cli_alert_warning("Not found: {basename(m)}")

  if (length(present) == 0) {
    cli_alert_info("No local files for tag {tag}, nothing to publish")
    next
  }

  vb_publish(present, repo = REPO, tag = tag)
  cli_alert_success("Published {length(present)} file(s) to {tag} (bus_manifest.json updated)")
}

cli_h1("Upload Complete")
cli_alert_info("Models are now available via: devtools::install_github('peteowen1/bouncermodels')")
