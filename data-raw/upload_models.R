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

# Which tags to publish. NULL = all. Set this to republish one family without
# touching the others -- which matters, because the three families are on
# different vintages and "publish everything" is not always the right act.
# Usage: TAGS <- "ball-outcome"; source("data-raw/upload_models.R")
if (!exists("TAGS")) TAGS <- NULL

cli_h1("Upload Models to bouncermodels")

if (!dir.exists(MODELS_DIR)) cli_abort("Models directory not found: {MODELS_DIR}")

# Define release tags and which models go where
releases <- list(
  # full_outcome_* is deliberately ABSENT (bouncerverse#50, 2026-08-19).
  #
  # Every full model that has ever existed was trained before the 2026-08-18
  # post-delivery leak fix, so publishing one would ship a model whose features
  # knew the delivery's own outcome. The three that were on this release were
  # removed rather than replaced: there is no correct one to replace them with
  # until the 3-way ELO inputs are rebuilt and it is retrained (#63, #65).
  #
  # bouncer's loaders now refuse an unstamped or pre-fix outcome model
  # (.check_model_vintage()), so a stale artefact cannot serve silently again.
  # Add full_outcome_* back here in the same commit that retrains them.
  "ball-outcome" = c(
    "agnostic_outcome_t20.ubj",
    "agnostic_outcome_odi.ubj",
    "agnostic_outcome_test.ubj"
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
  # test_win_probability.ubj is deliberately ABSENT (bouncerverse#52,
  # 2026-08-20). The v1 single-3-class Test model scored mlogloss 1.510 against
  # a base-rate baseline of 1.099 -- 37.2% WORSE than predicting the class
  # frequencies -- and nothing in bouncer had loaded it since v3 landed.
  # Publishing a model worse than a constant is worse than publishing nothing.
  # The decomposed v3 pair (test_result_model, test_conditional_win_model) is
  # what serves Test win probability.
  "in-match" = c(
    "odi_stage1_projected_score.ubj",
    "odi_stage2_win_probability.ubj",
    "test_stage1_projected_score.ubj",
    "test_result_model.ubj",
    "test_conditional_win_model.ubj"
  )
)

publish_tags <- if (is.null(TAGS)) names(releases) else intersect(TAGS, names(releases))
if (length(publish_tags) == 0) cli_abort("No matching tags in {.val {TAGS}}")
if (!is.null(TAGS)) cli_alert_info("Publishing only: {paste(publish_tags, collapse = ', ')}")

for (tag in publish_tags) {
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
