# Aggregate-Power Payload Estimation

MATLAB simulation and analysis tools for estimating payload mass and planar center of mass from aggregate electrical power and joint encoders. The project includes physical inversion, ridge and neural residual models, calibration, reference-assisted adaptation, and an electrothermal simulation model.

## Getting started

Download `simulation_data.zip` from the [releases page](https://github.com/kndx31415926/Physics-guided-payload-identification-from-aggregate-bus-power/releases). It contains the source code together with compact observations, fitted models, individual predictions, and simulation results. Extract the archive and open its `payload_power_simulation` directory in MATLAB:

```matlab
report = run_pipeline;
```

The default command recomputes descriptive statistics and predictions from saved models. It writes new results under `outputs/`.

```matlab
run_pipeline('summary')
run_pipeline('predictions')
run_pipeline('evaluation')
run_pipeline('online_statistics')
run_pipeline('training_plan')
run_pipeline('simulate_plan')
```

`run_pipeline('simulate')` generates one training-object probe. Feature-based retraining and full data-generation workflows are described in [Workflows](docs/WORKFLOWS.md). These operations are started explicitly and support separate output directories.

## Code and data

| Directory | Contents |
| --- | --- |
| `project/` | Simulation, training, calibration, and robot-interface code |
| `analysis/` | Portable prediction, statistics, training, and simulation entry points |
| `data/` | Compact observation-derived features and numeric analysis inputs |
| `studies/` | Generated results, fitted models, configurations, and associated source snapshots |
| `docs/` | Setup, workflows, data descriptions, and interface documentation |

The Git checkout contains code and documentation. The release archive also provides the data and model files needed by the analysis commands. Full raw trajectory archives are not included; the simulation code generates trajectories, and the retained compact data support saved-model inference, feature-based training, and statistical analysis.

The reference environment is MATLAB R2026a. See [Software requirements](docs/SOFTWARE.md) for the required toolboxes and [Quick start](docs/QUICK_START.md) for individual commands. `python verify_package.py` checks the distributed file hashes in the extracted archive.

- [Data catalog](docs/DATA_CATALOG.md)
- [Model and mathematical methods](docs/MODEL.md)
- [Simulation, training, and analysis workflows](docs/WORKFLOWS.md)
- [Robot-control and acquisition interfaces](docs/HARDWARE_INTERFACE.md)

Study identifiers and source snapshots retain their original names and checksums so that configurations, model files, and numerical results remain traceable. Use one source snapshot at a time: different simulation runs share MATLAB function names.
