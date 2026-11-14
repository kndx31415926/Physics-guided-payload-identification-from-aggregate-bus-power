# Software requirements

The reference environment is MATLAB R2026a on Windows. Keep the MATLAB JVM enabled for path handling and SHA256 checks. Saved MATLAB model objects are most reliably loaded with the reference release.

| Operation | Software |
| --- | --- |
| Descriptive statistics from CSV files | MATLAB; some percentile functions can require Statistics and Machine Learning Toolbox on older releases |
| Saved-model prediction and feature-based training | Deep Learning Toolbox and Statistics and Machine Learning Toolbox |
| Single-object simulation and physical inversion | Robotics System Toolbox and Optimization Toolbox |
| Complete simulation and training campaigns | The above toolboxes plus Parallel Computing Toolbox |
| MATLAB robot interface | `serialport`, a compatible device driver, and the configured robot |
| Python USB utilities | Python 3 with `pyserial` |
| Archive hash verification | Python 3 standard library |

The supplied neural training configuration runs on the CPU and does not require a GPU. Training trajectories can vary across MATLAB releases and numerical environments; the stored models allow a separate check of inference on the retained inputs.

The repository does not include MATLAB or its toolboxes. Device drivers and power acquisition are needed only for live robot use. Offline simulation and analysis do not require a connected robot.

Host-specific Windows launch scripts are available under `project/scripts/`. Some refer to `C:/new` and local executable paths; configure those paths before using them on another computer. The MATLAB commands in [Workflows](WORKFLOWS.md) use the extracted project location directly. Runs start on demand; the portable analysis entry points do not install startup jobs.
