PHYSICS-GUIDED PAYLOAD IDENTIFICATION FROM AGGREGATE BUS POWER
Supplementary code and data

This package contains simulation and training programs, fitted models,
observation-derived features, individual predictions and MATLAB figure sources.
Full raw power and encoder trajectories are omitted; the simulation programs
generate new trajectories.

QUICK START
Extract the archive, open MATLAB R2026a and change to this directory:
  report = run_review;

This command recomputes descriptive tables, predictions from the saved models
and the eight manuscript figures. Outputs are saved in review_outputs/.

Additional commands:
  run_review('evaluation')          PNN evaluation and paired-object bootstrap
  run_review('online_statistics')   PCU/PCR paired-stream statistics
  run_review('figures')             Eight manuscript figures
  run_review('training_plan')       Training configuration and requirements
  run_review('hardware_dry_run')    Robot-interface configuration

DIRECTORY GUIDE
  manuscript/   Article, mathematical supplement and figure sources
  data/         Compact PNN feature dataset
  studies/      Study data, models and associated source records
  matlab/       Package-relative reproduction functions
  project/      Simulation, training and robot-interface programs

SOFTWARE.txt lists dependencies. PROCESS_CODE_MAP.txt identifies data-generation,
training and analysis entry points. EVIDENCE_MAP.txt maps figures and tables to
their data. HARDWARE_INTERFACE.txt describes the connection and acquisition API.
Detailed training commands are in matlab/README_REVIEW_PNN.txt.

The supplied entry points select the appropriate study source tree. Use them
instead of adding all source trees recursively: studies share function names.
To verify distributed file sizes and SHA256 checksums:
  python verify_package.py
