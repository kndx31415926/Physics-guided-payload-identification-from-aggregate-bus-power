# Data catalog

The release archive retains simulation results, compact observation features, fitted models, individual predictions, and the configurations and source records associated with them. Values and study identifiers are preserved. Existing counts, failure flags, acceptance fields, and both raw and clipped predictions are part of the data.

## Main feature dataset

`data/pnn/pnn_dataset.mat` contains 22,000 episodes from 16,000 distinct objects:

- 12,000 training objects, with one episode per object.
- 2,000 validation objects, with one episode per object.
- 2,000 test objects, each observed under four conditions, giving 8,000 test trials.

The dataset contains 13- and 52-input feature representations, physical estimates, true parameters, eligibility masks, split labels, object and trial identities, configuration, and random-seed records. Its JSON manifest records the exported file hash and the input identities.

The matching `studies/pnn_large_training_20261031_v1/` directory supplies `model_bundle.mat`, selected-model records, `spec.json`, `predictions.csv`, `summary.csv`, paired intervals, and the associated `source_snapshot/`. Nine methods and two postprocessing variants yield 144,000 test-prediction rows.

`data/analysis_inputs/` contains numeric CSV and JSON subsets for statistical comparisons and mechanism analysis. These inputs complement the MAT datasets, individual predictions, and complete result records in `data/pnn/` and `studies/`.

## Result families

| Directory under `studies/` | Contents |
| --- | --- |
| `pgar_nominal_20261029_v1` | Compact-model development inputs and fitted model bundle |
| `pnn_large_training_20261031_v1` | Large feature dataset specifications, nine-method models, predictions, summaries, and paired comparisons |
| `psv_frozen_confirmation_20261030_v2` | Compact-model evaluation with 300 objects under four conditions; failure and timing records |
| `pvi_static_20261030_v2` | Static sensitivity, rank, independent torque checks, and multistart solutions |
| `pvi_solver_domain_20261030_v2` | Numerical inputs and domain subdivision for rank bounds |
| `pcu_prospective_20261030_v1` | Reference-assisted neural adaptation, reference updates, unknown-object predictions, and retention results |
| `pcr_online_ridge_20261031_v4` | Ridge adaptation on matched observations and neural/ridge stream comparisons |
| `psx_supplement_formal_20261106_v1` | Matched-loss development inputs, models, and a 500-object evaluation panel under four conditions |
| `pbd_exploration_20261110_v1` | Electrothermal sensitivity results for 12 paired objects at 13 conditions |
| `pca_convex_audit_20261111_v1` | Convex affine fits, convergence diagnostics, and evaluation on the shared panels |
| `pmd_mechanism_20261111_v1` | Power decomposition, local payload sensitivity, and holding-sample ledgers |

The electrothermal panel contains 156 episodes. Its power ledger retains eight poses and 31 holding samples per pose, totaling 38,688 samples. The 13 conditions include a shared zero-severity baseline along mechanical, electrical, and combined perturbation paths.

The adaptation data contain four drift scenarios, eight paired streams, and four update blocks. Each scenario has 128 unknown-object events, with prediction preceding each reference update. The PCU and PCR series share observations. Their command delay is fixed at 20 ms. The separate PSV series uses independent 10–15 ms command and feedback delays.

## Statistics and units

Payload parameters use kilograms and metres. Error summaries express mass absolute error in grams and Euclidean planar center-of-mass error in millimetres. Raw summaries retain finite predictions, including predictions marked as rejected. `common_clip` applies the shared output bounds. Acceptance, missingness, and error denominators are separate fields; they should not be conflated.

Paired test comparisons resample whole objects, preserving their condition pairing. Adaptation comparisons resample whole streams. Stream, block, pooled, terminal-block, and retention summaries describe different units and should be read with their corresponding prediction tables.

## Source records and trajectories

Each source snapshot belongs to its named study. Configuration files, plan identities, model hashes, and source manifests link the numerical results to the code and settings. Historic absolute paths record the origin of a run; portable analysis uses paths relative to the extracted package.

Full raw trajectories are not distributed. Compact features permit saved-model prediction and feature-based retraining. The simulation programs can generate observation traces from the recorded model configurations and seeds. New runs write to separate directories so that the retained results remain available for comparison.
