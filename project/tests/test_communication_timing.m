function info = test_communication_timing(run_name)
%TEST_COMMUNICATION_TIMING Short serial contract tests, not accuracy results.
% Run with no parallel pool. The oracle is copied from the immutable nominal
% source snapshot, renamed in the fresh test directory, and never modified.
if nargin<1,run_name=['communication_timing_contracts_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))];end
root=fileparts(fileparts(mfilename('fullpath')));addpath(root);cfg=startup_bpil();
maxNumCompThreads(1);
assert(isempty(gcp('nocreate')),'bpil:TestPool','Run these small tests in a fresh MATLAB process without a pool.');
outdir=fullfile(root,'results',run_name);
assert(~isfolder(outdir),'bpil:TestExists','Choose a fresh test output directory.');mkdir(outdir);
oracle_path=fullfile(root,'results','pgar_nominal_20261029_v1','source_snapshot','src','bpil_simulate_probe.m');
oracle_source=fileread(oracle_path);
oracle_source=strrep(oracle_source,'function [obs,truth] = bpil_simulate_probe(', ...
    'function [obs,truth] = bpil_communication_legacy_oracle(');
assert(contains(oracle_source,'function [obs,truth] = bpil_communication_legacy_oracle('));
fid=fopen(fullfile(outdir,'bpil_communication_legacy_oracle.m'),'w');
assert(fid>=0);fwrite(fid,oracle_source);fclose(fid);addpath(outdir);
path_cleanup=onCleanup(@()rmpath(outdir)); %#ok<NASGU>
cfg.sim.initial_hold_s=.10;cfg.sim.move_s=.15;cfg.sim.hold_s=.25;
probes=bpil_probe_library(cfg);probe=probes(2);probe.id='SHORT_CONTRACT_FIXTURE_NOT_ACCURACY';
probe.poses=[probe.poses(1,:);probe.poses(1,:)+[.020 .025 -.020 .015]];
payload=struct('mass',.15,'com',[.12 0 .005],'dimensions_m',cfg.payload.dimensions_m);
drift=bpil_drift(1,1,'common');sensor_seed=551801;
fixed=struct('command_delay_s',[.0125 .0125],'encoder_delay_s',[.0125 .0125],'seed',812301);
jitter=struct('command_delay_s',[.010 .015],'encoder_delay_s',[.010 .015],'seed',812301);
passed={};started=tic;

% Delay draws are deterministic, independent per channel and independent of
% global MATLAB randomness. Large schedules are cheap; no plant is run here.
rng_before=rng;S=bpil_communication_schedule(jitter,sensor_seed,.001,500000,50);
assert(isequaln(rng_before,rng),'Schedule leaked global RNG state.');
assert(isequaln(S,bpil_communication_schedule(jitter,sensor_seed,.001,500000,50)));
F=bpil_communication_schedule(fixed,sensor_seed,.001,900,50);
assert(all(F.command_packets.requested_delay_s==.0125));
assert(all(abs(F.command_packets.applied_delay_s-.013)<1e-14));
assert(all(abs(F.encoder_packets.applied_delay_s-.013)<1e-14));
for name={'command_packets','encoder_packets'}
    p=S.(name{1});
    assert(all(p.requested_delay_s>=.010 & p.requested_delay_s<=.015));
    assert(all(p.applied_delay_s>=p.requested_delay_s-1e-14));
    assert(all(p.applied_delay_s-p.requested_delay_s<.001+1e-14));
    assert(isequal(unique(round(p.applied_delay_s*1000)),(11:15)'));
    assert(abs(mean(p.requested_delay_s)-.0125)<.00005);
    assert(abs(mean(p.applied_delay_s)-.013)<.00005);
end
changed=jitter;changed.encoder_delay_s=[0 0];
SE=bpil_communication_schedule(changed,sensor_seed,.001,500000,50);
assert(isequaln(S.command_packets,SE.command_packets),'Encoder stream altered command delays.');
changed=jitter;changed.command_delay_s=[0 0];
SC=bpil_communication_schedule(changed,sensor_seed,.001,500000,50);
assert(isequaln(S.encoder_packets,SC.encoder_packets),'Command stream altered encoder delays.');
assert(~isequal(S.command_packets.requested_delay_s,S.encoder_packets.requested_delay_s));
passed{end+1}='Independent reproducible RNG, uniform bounds, and explicit ceil-to-1ms discretization';

bad={struct('command_delay_s',[.015 .010],'encoder_delay_s',[0 0]), ...
    struct('command_delay_s',[-.001 .01],'encoder_delay_s',[0 0]), ...
    struct('command_delay_s',[0 NaN],'encoder_delay_s',[0 0]), ...
    struct('command_delay_s',[.05 .05],'encoder_delay_s',[0 0]), ...
    struct('command_delay_s',[0 0],'encoder_delay_s',[.0495 .0495]), ...
    struct('command_delay_s',[0 0],'encoder_delay_s',[0 0],'seed',.5)};
for j=1:numel(bad),must_fail(@()bpil_communication_schedule(bad{j},sensor_seed,.001,900,50));end
passed{end+1}='Invalid delays and seeds rejected, including delays that round to one whole period';

[legacy_obs,legacy_truth]=bpil_communication_legacy_oracle(cfg,payload,probe,drift,sensor_seed);
rng_before=rng;[default_obs,default_truth]=bpil_simulate_probe(cfg,payload,probe,drift,sensor_seed);
assert(isequaln(rng_before,rng),'Simulation leaked global RNG state.');
assert(isequaln(default_obs,legacy_obs),'Default observations changed relative to frozen original simulator.');
assert(isequaln(default_truth,legacy_truth),'Default truth changed relative to frozen original simulator.');
assert(default_truth.physical_success&&numel(default_obs.t)==90,'Short fixture did not complete physically.');
passed{end+1}='Default full outputs exactly equal the immutable original simulator';

matched_cfg=cfg;matched_cfg.sim.communication=struct('command_delay_s',[.020 .020], ...
    'encoder_delay_s',[0 0],'seed',812301);
[matched_obs,matched_truth]=bpil_simulate_probe(matched_cfg,payload,probe,drift,sensor_seed);
assert(isequaln(rmfield(matched_obs,'communication'),default_obs),'Opt-in nominal timing changed observations.');
for name={'q','dq','tau','P','plateau_speed_rms_rad_s','plateau_dynamic_torque_rms_Nm'}
    assert(isequaln(matched_truth.(name{1}),default_truth.(name{1})));
end
passed{end+1}='Opt-in 20ms commands and zero-delay encoders reproduce legacy physics and readings';

fixed_cfg=cfg;fixed_cfg.sim.communication=fixed;
[fixed_obs,fixed_truth]=bpil_simulate_probe(fixed_cfg,payload,probe,drift,sensor_seed);
jitter_cfg=cfg;jitter_cfg.sim.communication=jitter;
rng_before=rng;[jitter_obs,jitter_truth]=bpil_simulate_probe(jitter_cfg,payload,probe,drift,sensor_seed);
assert(isequaln(rng_before,rng),'Jitter simulation leaked global RNG state.');
[repeat_obs,repeat_truth]=bpil_simulate_probe(jitter_cfg,payload,probe,drift,sensor_seed);
assert(isequaln(jitter_obs,repeat_obs)&&isequaln(jitter_truth,repeat_truth),'Repeated jitter run differs.');
passed{end+1}='Complete jitter simulation is deterministic and preserves caller RNG';

assert(fixed_truth.physical_success&&jitter_truth.physical_success);
check_timing(fixed_obs,fixed_truth);check_timing(jitter_obs,jitter_truth);
assert(all(abs(fixed_truth.communication.command_packets.applied_delay_s-.013)<1e-14));
assert(all(abs(fixed_truth.communication.encoder_packets.applied_delay_s-.013)<1e-14));
assert(numel(unique(jitter_truth.communication.command_packets.applied_delay_s))>1);
assert(numel(unique(jitter_truth.communication.encoder_packets.applied_delay_s))>1);
passed{end+1}='50ms command/encoder and 10ms power periods remain fixed; real packet application follows delays';

assert(isequaln(fixed_obs.t,jitter_obs.t)&&isequaln(fixed_obs.q_command,jitter_obs.q_command));
assert(max(abs(fixed_truth.q-jitter_truth.q),[],'all')>1e-10,'Command delays affected only logs, not actual plant.');
assert(max(abs(fixed_truth.P-jitter_truth.P))>1e-10,'Command delays did not change plant power.');
assert(max(abs((fixed_obs.P-fixed_truth.P)-(jitter_obs.P-jitter_truth.P)))<1e-12, ...
    'Timing RNG changed paired power noise.');
passed{end+1}='Command jitter changes physical trajectory and power while preserving paired sensor noise';

no_encoder_cfg=jitter_cfg;no_encoder_cfg.sim.communication.encoder_delay_s=[0 0];
[no_encoder_obs,no_encoder_truth]=bpil_simulate_probe(no_encoder_cfg,payload,probe,drift,sensor_seed);
for name={'q','dq','tau','P'},assert(isequaln(no_encoder_truth.(name{1}),jitter_truth.(name{1})));end
assert(isequaln(no_encoder_obs.P,jitter_obs.P));
assert(isequaln(no_encoder_obs.q_command,jitter_obs.q_command));
assert(~isequaln(no_encoder_obs.q,jitter_obs.q),'Encoder transport delay did not affect observed angles.');
check_timing(no_encoder_obs,no_encoder_truth);
passed{end+1}='Encoder return delay changes only host observations, not local PID feedback or power sampling';

changed_seed_cfg=jitter_cfg;changed_seed_cfg.sim.communication.seed=jitter.seed+1;
[changed_seed_obs,changed_seed_truth]=bpil_simulate_probe(changed_seed_cfg,payload,probe,drift,sensor_seed);
assert(~isequaln(changed_seed_truth.communication.command_packets.requested_delay_s, ...
    jitter_truth.communication.command_packets.requested_delay_s));
assert(~isequaln(changed_seed_truth.q,jitter_truth.q));
assert(max(abs((changed_seed_obs.P-changed_seed_truth.P)-(jitter_obs.P-jitter_truth.P)))<1e-12);
check_timing(changed_seed_obs,changed_seed_truth);
passed{end+1}='Changing only the communication seed changes jitter without changing measurement-noise draws';

% Observable metadata must never include unreceived packet values or the
% hidden robot command-application timestamp; these are truth-only audits.
assert(~isfield(jitter_obs.communication,'command_packets'));
assert(all(jitter_obs.communication.encoder_packets.receive_t<=jitter_obs.t(end)+1e-12));
last=jitter_truth.communication.encoder_packets;
assert(isnan(last.receive_t(end))&&last.scheduled_receive_t(end)>jitter_obs.t(end));
assert(numel(jitter_obs.communication.encoder_packets.sequence)==numel(last.sequence)-1);
passed{end+1}='Unreceived final encoder packet and hidden command application times are absent from inference observations';

info=struct('scope','DEVELOPMENT CONTRACT TEST ONLY: short two-pose simulations, no accuracy claim.', ...
    'passed_groups',{passed},'passed_count',numel(passed),'elapsed_s',toc(started), ...
    'oracle_source',oracle_path,'run_dir',outdir,'simulated_duration_s',.9, ...
    'plant_runs',8,'parallel_pool_used',false, ...
    'uniform_requested_delay_mean_ms',1000*mean(S.command_packets.requested_delay_s), ...
    'uniform_applied_delay_mean_ms',1000*mean(S.command_packets.applied_delay_s));
save(fullfile(outdir,'TEST_PASS.mat'),'info','cfg','probe','payload','fixed','jitter', ...
    'default_obs','default_truth','fixed_obs','fixed_truth','jitter_obs','jitter_truth', ...
    'no_encoder_obs','no_encoder_truth','changed_seed_obs','changed_seed_truth','-v7');
for j=1:numel(passed),fprintf('PASS %02d: %s\n',j,passed{j});end
fprintf('COMMUNICATION TIMING CONTRACTS PASS: %d groups, %.3f s; %s\n',numel(passed),info.elapsed_s,outdir);
end

function check_timing(obs,truth)
tol=1e-12;C=truth.communication.command_packets;E=truth.communication.encoder_packets;
assert(all(abs(diff(C.issued_t)-.050)<tol),'Command period changed.');
assert(all(abs(diff(E.sample_t)-.050)<tol),'Encoder sampling period changed.');
assert(all(abs(diff(obs.t)-.010)<tol),'Power sample period changed.');
assert(numel(obs.t)==90&&numel(C.issued_t)==18&&numel(E.sample_t)==18);
assert(all(abs(C.applied_t-C.scheduled_apply_t)<tol),'Command application time differs from schedule.');
assert(all(abs(C.applied_t-C.issued_t-C.applied_delay_s)<tol));
received=isfinite(E.receive_t);
assert(all(abs(E.receive_t(received)-E.scheduled_receive_t(received))<tol));
assert(all(abs(E.receive_t(received)-E.sample_t(received)-E.applied_delay_s(received))<tol));
A=obs.communication;
assert(all(A.power_record_encoder_receive_t<=obs.t+tol),'Readout used before packet arrived.');
assert(all(A.power_record_encoder_sample_t<=A.power_record_encoder_receive_t+tol));
for k=1:numel(obs.t)
    idx=find(received & E.receive_t<=obs.t(k)+tol,1,'last');
    if isempty(idx)
        expected_q=A.initial_encoder_q;sample_t=0;receive_t=0;
    else
        expected_q=E.q(idx,:);sample_t=E.sample_t(idx);receive_t=E.receive_t(idx);
    end
    assert(isequaln(obs.q(k,:),expected_q),'Power record does not use latest arrived encoder packet.');
    assert(abs(A.power_record_encoder_sample_t(k)-sample_t)<tol);
    assert(abs(A.power_record_encoder_receive_t(k)-receive_t)<tol);
end
end

function must_fail(f)
failed=false;
try,f();catch ME,failed=strcmp(ME.identifier,'bpil:Communication');end
assert(failed,'Invalid communication specification was not rejected.');
end
