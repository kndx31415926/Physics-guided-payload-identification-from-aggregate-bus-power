# Quick start

Extract `simulation_data.zip` and open the extracted `payload_power_simulation` directory in MATLAB R2026a. The archive contains the code, data, and fitted models required by these commands.

```matlab
packageRoot = pwd;
report = run_pipeline;
```

The default run recomputes descriptive summaries from stored individual predictions and applies the saved estimators to the compact test features. Each invocation writes to a new directory under `outputs/`.

| Command | Operation |
| --- | --- |
| `run_pipeline('summary')` | Recompute errors, counts, and coverage from individual prediction rows |
| `run_pipeline('predictions')` | Apply nine saved estimators to 8,000 test trials |
| `run_pipeline('evaluation')` | Saved-model inference and 5,000 paired-object bootstrap resamples |
| `run_pipeline('online_statistics')` | Reference-adaptation statistics with 4,000 whole-stream bootstrap resamples |
| `run_pipeline('training_plan')` | Inspect the feature-based training configuration |
| `run_pipeline('simulate_plan')` | Inspect a single-object simulation configuration |
| `run_pipeline('simulate')` | Generate one training-object probe and its features |
| `run_pipeline('hardware_dry_run')` | Inspect the robot-interface configuration without opening the device |

The `summary` action handles point estimates and coverage. Use `evaluation` and `online_statistics` for confidence intervals, preserving the object and stream resampling units respectively.

For direct entry points:

```matlab
addpath(fullfile(packageRoot, 'analysis'));
report = payload_pnn_predictions(packageRoot);
plan = payload_pnn_retrain(packageRoot);
```

See [Workflows](WORKFLOWS.md) for data generation, retraining, and manual restart commands. See [Data catalog](DATA_CATALOG.md) for file identities and units.
