# Robot control and power acquisition

The control interface separates joint commands, encoder feedback, and power acquisition. Configuration is stored in the robot profile, while the acquisition provider supplies timestamped measurements.

```matlab
packageRoot = pwd;
addpath(fullfile(packageRoot, 'project'));
configuration = run_robot_control();
```

The default call is a dry run. A live call uses `mode='hardware'` and `enable_hardware=true`. `action='inspect'` requests encoder feedback; `action='trajectory'` follows the supplied joint plan. Configure the serial port, joint mapping, offsets, and limits for the attached robot. `project/ROBOT_CONTROL.txt` lists the options.

Control modules:

- `project/src/bpil_arm_control_profile.m`
- `project/src/bpil_arm_plan.m`
- `project/src/bpil_arm_serial_transport.m`
- `project/src/bpil_arm_control_loop.m`
- `project/src/bpil_arm_preflight.m`

For acquisition and estimation:

```matlab
modelFile = fullfile(packageRoot, 'studies', ...
    'pgar_nominal_20261029_v1', 'model_bundle.mat');
configuration = run_hardware_hefting( ...
    struct('mode', 'dry_run', 'model_file', modelFile));
```

The estimator accepts the `pgar_residual_bundle_v1` format. The power-provider factory returns timestamped `Vin_V` and `Iin_A` samples on the transport's monotonic clock. Their product supplies bus power. Command and encoder scheduling uses a 50 ms period; payload estimation follows the completed probing sequence.

`project/docs/HARDWARE_INTERFACE.txt` defines timestamps, sample fields, and session/replay formats. MATLAB interfaces use `serialport`. Python USB utilities under `project/scripts/roarm_*` use `pyserial`. Interface tests are in `project/tests/`.
