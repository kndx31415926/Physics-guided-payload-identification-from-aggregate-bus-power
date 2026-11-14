function report=pix_test_probe_smoke(family,severity)
%PIX_TEST_PROBE_SMOKE Exactly one complete probe; no large-run launcher.
% No models are loaded or trained. Original pnn_features is read-only.
caller_rng=rng;rng_cleanup=onCleanup(@()rng(caller_rng)); %#ok<NASGU>
if nargin<1,family='combined';end
if nargin<2,severity=0;end
root=fileparts(fileparts(mfilename('fullpath')));addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
cfg=bpil_config(root);S=pix_config(cfg);C=pix_condition(S,family,severity,2096110601);
probes=bpil_probe_library(cfg);probe=probes(2);
payload=struct('mass',.15,'com',[.12 0 .004],'dimensions_m',cfg.payload.dimensions_m);
comm=struct('command_delay_s',[.010 .015],'encoder_delay_s',[.010 .015],'seed',2096110701);
t=tic;[obs,truth]=pix_simulate_probe(cfg,payload,probe,C,2096110801,comm,S);elapsed=toc(t);
f=pnn_features(cfg,obs,struct('scale',[.14 .14 .036],'probe_id','probe_02','gn_lambda',.001));
report=struct('scope','One explicitly authorized complete simulation smoke; not confirmatory accuracy.', ...
    'family',family,'severity',severity,'elapsed_s',elapsed,'obs',obs,'truth',truth,'features',f, ...
    'completed',truth.simulated_duration_s>=22.6-1e-9,'stationary',all(obs.stationary), ...
    'feature_usable',f.usable,'energy_pass',truth.energy.pass);
end
