# Simulation, training, and analysis

All paths below are relative to the extracted `payload_power_simulation` directory unless stated otherwise. Use the release archive when data or fitted models are required.

## Analyze retained results

```matlab
run_pipeline('summary');
run_pipeline('predictions');
run_pipeline('evaluation');
run_pipeline('online_statistics');
```

The summary workflow recomputes descriptive errors, counts, and coverage from individual predictions. The prediction workflow loads the saved nine-method bundle. Evaluation adds 5,000 paired-object resamples. Online statistics use 4,000 whole-stream resamples. All methods and both `raw` and `common_clip` outputs remain available.

## Train on compact observations

```matlab
packageRoot = pwd;
addpath(fullfile(packageRoot, 'analysis'));
plan = payload_pnn_retrain(packageRoot);

outputDirectory = fullfile(packageRoot, 'outputs', 'feature_training_01');
result = payload_pnn_retrain(packageRoot, outputDirectory, true, false);
```

Training uses the 12,000 training and 2,000 validation objects, the specified hyperparameter grids, and the recorded seeds. Test objects are not supplied to fitting or model selection. This workflow trains from the compact features; it does not regenerate ODE trajectories.

To restart an interrupted run, use the same output directory:

```matlab
result = payload_pnn_retrain(packageRoot, outputDirectory, true, true);
```

The resume check compares data, source, configuration, MATLAB release, and checkpoint identities. Neural training resumes from optimizer checkpoints; `fitrnet` ensembles resume between completed seeds. Completed models are reused after their identities are checked. Keep the original output path when restarting, because it is part of the recorded identity. Training is started manually and can take many hours.

## Generate a probe trace

```matlab
packageRoot = pwd;
addpath(fullfile(packageRoot, 'analysis'));
outputDirectory = fullfile(packageRoot, 'outputs', 'probe_3000001');
plan = payload_simulate_example(packageRoot, outputDirectory, 3000001);
result = payload_simulate_example(packageRoot, outputDirectory, 3000001, true);
```

The example chooses one object from the recorded training split. It loads its configuration, condition, and random seeds, then calls `pnn_conditions`, `pnn_expected_record`, `pnn_trial`, and `pnn_features` from the matching source snapshot. Outputs contain a new observation/truth trace, the 13/52-input features, physical estimates, and an eight-pose observation CSV when available. Use a new output directory for a new attempt.

The shorthand `run_pipeline('simulate_plan')` displays the default example, and `run_pipeline('simulate')` executes it.

## Generate and train a full campaign

The full workflow first generates training and validation trajectories, extracts features, and fits models. It locks the selected model bundle before generating and evaluating the independent test panel.

From the package root:

```matlab
packageRoot = pwd;
projectRoot = fullfile(packageRoot, 'project');
addpath(projectRoot);
runName = ['pnn_run_' char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'))];
runDirectory = prepare_pnn_run(runName, struct('workers', 1));

snapshot = fullfile(runDirectory, 'source_snapshot');
cd(snapshot);
clear run_pnn_job
run_pnn_job(runDirectory);
```

`prepare_pnn_run` creates `project/results/<runName>/`, records the configuration and seeds, and copies a source snapshot. Its default design contains 12,000 training, 2,000 validation, and 2,000 test objects. Four paired test conditions produce 22,000 total episodes. Preparation does not execute the campaign.

Run `run_pnn_job` from the newly created `source_snapshot` directory. It verifies the source and input identities and continues completed generation/training stages from checkpoints. After an interruption, return to that same snapshot and call `run_pnn_job(runDirectory)` again. Do not call `prepare_pnn_run` again for an existing run. A completed run is recognized through its completion record. Failure records and partial outputs remain in the run directory.

The original job runners reset MATLAB's path to their selected snapshot. Avoid `addpath(genpath(...))` across all study directories, because snapshots share function names.

## Other simulation families

| Task | Preparation and execution | Core implementation |
| --- | --- | --- |
| Compact estimator | `prepare_pgar_run`, `run_pgar_job` | `pgar_generate_data`, `pgar_train_models`, `pgar_model_predict` |
| Frozen-model perturbations | `prepare_psv_run`, `run_psv_job` | `psv_plan`, `psv_generate_data`, `psv_evaluate`, `psf_train` |
| Neural reference adaptation | `prepare_pcu_run`, `run_pcu_job` | `pcu_data_plan`, `pcu_generate_data`, `prb_online_init`, `pcu_run_online` |
| Ridge reference adaptation | `prepare_pcr_run`, `run_pcr_job` | `pcr_online_init`, `pcr_run_online`, `pcr_compare_models` |
| Matched affine controls | `prepare_psx_run`, `run_psx_job` | `pfl_spec`, `pfl_train`, `psx_evaluate` |
| Electrothermal sensitivity | `prepare_pbd_run`, `run_pbd_job` | `pix_condition`, `pix_simulate_probe`, `pbd_analyze` |
| Convex affine fitting | `prepare_pca_run`, `run_pca_job` | `pca_train`, `pca_objective`, `pca_solve_affine` |
| Static identifiability | `pvi_run_static_validation` | Sensitivity, rank, torque comparisons, multistart solves |
| Domain rank bounds | `pvi_run_solver_domain` | Box subdivision and singular-value bounds |
| Power decomposition | `project/scripts/pmd_analyze_20261111.m` | Holding-sample, pose, and episode ledgers |

The dependent runners expect parent results under `project/results/<study>/`. Their preparation functions specify the required configuration and model paths. PSV uses compact-model configurations and selected baselines; PCU uses compact development features and retention probes; PCR uses PCU observations and ridge initialization. PSX/PBD use the large-model development data and selected models. PCA uses matched-affine starting models and shared evaluation inputs.

For new end-to-end dependent campaigns, generate the parent run data and map its paths before preparing the dependent run. The packaged study directories contain compact inputs and outcomes, not every parent raw trajectory. Use the portable analysis workflows for direct analysis of the retained datasets.
