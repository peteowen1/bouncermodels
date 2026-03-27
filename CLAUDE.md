# CLAUDE.md

Pre-trained ML models for cricket analytics, served via GitHub releases with local caching.

## Package Overview

**bouncermodels** provides pre-trained models for the bouncer R package. Minimal package (2 R files) — no data processing logic, just model loading and caching.

## Development Commands

```r
devtools::load_all()
devtools::test()
devtools::check()
devtools::document()
```

## Architecture

### R Code (2 files)
- `R/load_model.R` — All exports: `load_bouncer_model()`, `list_available_models()`, `check_model_cache()`, `clear_model_cache()`
- `R/bouncermodels-package.R` — Package docs

### Model Categories

| Release Tag | Models | Format | Source |
|-------------|--------|--------|--------|
| `ball-outcome` | agnostic_outcome_{t20,odi,test}, full_outcome_{t20,odi,test} | .ubj | bouncer pipeline steps 2, 7 |
| `prediction` | {t20,odi,test}_prediction_model, {t20,odi,test}_margin_model, ipl_prediction_model | .ubj | bouncer pipeline step 9 |
| `in-match` | odi/test stage1/stage2 projected score, win probability | .ubj | bouncer pipeline step 12 |

### Caching

Models cache to `tools::R_user_dir("bouncermodels", "cache")/models/`. Use `force_download = TRUE` to bypass cache.

### Uploading Models

After retraining models in the bouncer pipeline:
```r
Rscript data-raw/upload_models.R
```

## Related Projects

Part of the bouncerverse ecosystem. See `~/OneDrive/Documents/bouncerverse/CLAUDE.md` for the monorepo overview. Mirrors the torpmodels pattern from torpverse. For full ecosystem: `~/OneDrive/Documents/ECOSYSTEM.md`
