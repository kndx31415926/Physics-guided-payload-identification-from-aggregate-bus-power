# Physics-guided payload identification from aggregate bus power

Mathematical supplement, simulation and training programs, fitted models, derived data, and MATLAB figure programs accompanying the study by Zhenglin Li, Peizhong Li, Ting Zhu and Yi Li.

## Downloads

- [Mathematical supplement (PDF)](mathematics/supplement.pdf)
- [Mathematical supplement (LaTeX)](mathematics/supplement.tex)
- [Complete supplementary code and data](https://github.com/kndx31415926/Physics-guided-payload-identification-from-aggregate-bus-power/releases/download/v1.0.0/Supplementary_code_and_data.zip)
- [Figure data and MATLAB plotting programs](https://github.com/kndx31415926/Physics-guided-payload-identification-from-aggregate-bus-power/releases/download/v1.0.0/Figure_data.zip)
- [All release files](https://github.com/kndx31415926/Physics-guided-payload-identification-from-aggregate-bus-power/releases/tag/v1.0.0)

The complete archive contains simulation, data generation, training, evaluation, statistical analysis, figure reproduction and robot-interface programs, together with fitted models, compact observations and individual predictions. Full raw trajectories can be generated with the supplied simulation programs. File hashes are listed in [SHA256SUMS.txt](SHA256SUMS.txt).

## Reproduction

Extract `Supplementary_code_and_data.zip`, open MATLAB, and change to the extracted `reviewer_code_and_data` directory. Run:

```matlab
report = run_review;
```

This recomputes descriptive tables, saved-model predictions and the eight manuscript figures. Results are written to `review_outputs/`.

Selected entries:

```matlab
run_review('evaluation')
run_review('online_statistics')
run_review('figures')
run_review('training_plan')
```

The reference environment is MATLAB R2026a. Saved-model inference uses Deep Learning Toolbox and Statistics and Machine Learning Toolbox. Full simulation campaigns additionally use Optimization Toolbox, Robotics System Toolbox and Parallel Computing Toolbox.

- [Quick start](docs/README_FIRST.txt)
- [Software requirements](docs/SOFTWARE.txt)
- [Data-generation and training entry points](docs/PROCESS_CODE_MAP.txt)
- [Figures, tables and data sources](docs/EVIDENCE_MAP.txt)
- [Robot-interface programs](docs/HARDWARE_INTERFACE.txt)

The supplied entry points select the relevant study source tree; study trees share function names. Package integrity can be checked from the extracted directory with `python verify_package.py`.

## Correspondence

Yi Li, School of Art and Design, Wuhan Institute of Technology, No. 206 Guanggu Street, Hongshan District, Wuhan 430205, China.

Email: 13323107655@163.com  
ORCID: [0009-0000-9541-8300](https://orcid.org/0009-0000-9541-8300)
