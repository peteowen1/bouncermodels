# CLAUDE.md

Pre-trained ML models for cricket analytics, served via GitHub releases with local caching.

## Docs

Git workflow (branch, PR-to-main) is in the global and parent CLAUDE.md, not restated here. Verse-level docs (reviews, plans, decision log, work queue) live in the parent's `bouncerverse/docs/` — start at `../docs/HOME.md`.

## Package Overview

**bouncermodels** provides pre-trained models for the bouncer R package. Minimal package (3 R files) — no data processing logic, just model loading and caching.

## Development Commands

```r
devtools::load_all()
devtools::test()
devtools::check()
devtools::document()
```

## Architecture

### R Code (3 files)
- `R/load_model.R` — All exports: `load_bouncer_model()`, `list_available_models()`, `check_model_cache()`, `clear_model_cache()`
- `R/bouncermodels-package.R` — Package docs
- `R/versebus.R` — Vendored, canonical copy is `torpverse/torp/R/versebus.R`; `test-versebus-sync.R` pins this file's contents to it byte-for-byte — never edit locally, sync from torp instead

### Model Categories

| Release Tag | Models | Format | Source |
|-------------|--------|--------|--------|
| `ball-outcome` | agnostic_outcome_{t20,odi,test}, full_outcome_{t20,odi,test} | .ubj | bouncer pipeline steps 2, 7 |
| `prediction` | {t20,odi,test}_prediction_model, {t20,odi,test}_margin_model, ipl_prediction_model | .ubj | bouncer pipeline step 9 |
| `in-match` | {t20,odi}_stage{1,2}_results, {t20,odi}_innings1_results, test_stage1_results, test_winprob_v3_results | .rds (bundle: `$model` + `$feature_cols`, not a bare model — bouncerverse#81/D-P54) | bouncer pipeline step 12 |

### Caching

Models cache to `tools::R_user_dir("bouncermodels", "cache")/models/`. Use `force_download = TRUE` to bypass cache.

### Uploading Models

After retraining models in the bouncer pipeline:
```r
Rscript data-raw/upload_models.R
```

## Related Projects

Part of the bouncerverse ecosystem. See `C:\dev\bouncerverse\CLAUDE.md` for the monorepo overview. Mirrors the torpmodels pattern from torpverse. For full ecosystem: `C:\dev\ECOSYSTEM.md`
