function report=test_hardware_hefting_contracts()
%TEST_HARDWARE_HEFTING_CONTRACTS Persistence, provenance and reference labels.
% Independent contract tests. No device is opened and no frozen experiment
% or trained model is modified; all mutable fixtures live in a new folder.
root=fileparts(fileparts(mfilename('fullpath')));
addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'), ...
    fullfile(root,'tests','helpers'));
started=tic;checks={};
folder=fullfile(root,'results',['hardware_hefting_contracts_v2_' ...
    char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
assert(~isfolder(folder),'test:Exists','Use a fresh result directory.');mkdir(folder);
original=fullfile(root,'results','pgar_nominal_20261029_v1','model_bundle.mat');
original_hash=prc_file_hash(original);model_file=fullfile(folder,'model_bundle_mock_copy.mat');
copyfile(original,model_file);a=load(original,'bundle');cfg=a.bundle.cfg;cfg.root=root;
probes=bpil_probe_library(cfg);probe=probes(2);H=profile();
[T,power,inspect]=bpil_mock_hefting_transport(H,cfg,probe);
factory_calls=0;provider_poll_calls=0;provider_close_calls=0;clock=[];
file=fullfile(folder,'complete_mock_capture.mat');
opts=struct('mode','mock','cfg',cfg,'hardware',H,'probe',probe,'transport',T, ...
    'power_provider_factory',@factory,'model_file',model_file,'output_file',file);
R=run_hardware_hefting(opts);S=inspect();
assert(R.completed&&R.prediction.accepted&&~R.hardware_opened&&~R.hardware_validated);
assert(factory_calls==1&&provider_poll_calls>2000&&provider_close_calls==1&&S.close_count==1);
assert(all(cellfun(@(x)x.T~=107,S.sent)),'test:TorqueWrite','Read-only torque verification must not write a torque limit.');
checks{end+1}='clock-bound power-provider factory polls and closes exactly once';
assert(isfile(file));saved=load(file,'session_result');
assert(isequaln(saved.session_result,R));
checks{end+1}='explicit output_file persists the full session_result';

replay=struct('mode','replay','session',R,'transport',forbidden_transport(), ...
    'power_provider',@forbidden_io);
RR=run_hardware_hefting(replay);
assert(strcmp(RR.model_file,model_file)&&strcmp(RR.model_sha256,prc_file_hash(model_file)));
assert(isequaln(RR.obs,R.obs)&&isequaln(RR.prediction.theta,R.prediction.theta));
checks{end+1}='default replay binds the recorded model path/hash and reproduces inference without I/O';
wrong=R;wrong.model_sha256=repmat('0',1,64);badreplay=replay;badreplay.session=wrong;
expect_error(@()run_hardware_hefting(badreplay),'bpil:ReplayModelChanged');
changed_file=fullfile(folder,'changed_model_copy.mat');copyfile(model_file,changed_file);
fid=fopen(changed_file,'ab');assert(fid>=0);fwrite(fid,uint8(0));fclose(fid);
wrong=R;wrong.model_file=changed_file;badreplay.session=wrong;
expect_error(@()run_hardware_hefting(badreplay),'bpil:ReplayModelChanged');
checks{end+1}='recorded model hash mismatch and subsequently changed model content are rejected';

known=[.15 .12 .005];ref=bpil_hefting_known_reference(file,'reference_train',known);
assert(isequal(ref.obs,R.obs)&&isequal(ref.known_theta,known)&&ref.is_reference&&ref.capture_is_mock);
assert(strcmp(ref.record_hash,prc_file_hash(file))&&strcmp(ref.role,'reference_train'));
assert(strcmp(ref.label_source,'explicit_independently_known_reference'));
checks{end+1}='known-reference conversion preserves actual observations, independent labels and capture SHA';
session_result=R;session_result.prediction=struct('theta',[999 888 777]); %#ok<NASGU>
poisoned=fullfile(folder,'prediction_label_injection_fixture.mat');save(poisoned,'session_result');
ref2=bpil_hefting_known_reference(poisoned,'reference_validation',known);
assert(isequal(ref2.known_theta,known)&&isequal(ref2.obs,R.obs));
assert(strcmp(ref2.record_hash,prc_file_hash(poisoned)));
expect_error(@()bpil_hefting_known_reference(file,'unknown',known),'bpil:ReferenceRole');
checks{end+1}='stored network predictions cannot replace independent labels and unknown roles are rejected';

[ET,~,ei]=bpil_mock_hefting_transport(H,cfg,probe);
guarded=opts;guarded.transport=ET;guarded.power_provider_factory=@forbidden_io;
expect_error(@()run_hardware_hefting(guarded),'bpil:SessionExists');
ES=ei();assert(isempty(ES.sent)&&ES.poll_calls==0&&ES.power_calls==0&&ES.close_count==0);
checks{end+1}='an existing output filename is rejected before any transport or provider I/O';
guarded.output_file=fullfile(folder,'must_not_be_created_bad_eta.mat');
guarded.eta=struct('coefficients',[-1 zeros(1,12)]);
expect_error(@()run_hardware_hefting(guarded),'pra:Calibration');
ES=ei();assert(isempty(ES.sent)&&ES.poll_calls==0&&ES.power_calls==0&&ES.close_count==0);
assert(~isfile(guarded.output_file));
checks{end+1}='invalid physical calibration coefficients are rejected before device I/O';

[FT,FP,fi]=bpil_mock_hefting_transport(H,cfg,probe);
failed_opts=rmfield(opts,'power_provider_factory');failed_opts.transport=FT;failed_opts.power_provider=FP;
failed_opts.stop_requested=@()FT.now()>=.5;failed_opts.output_file=fullfile(folder,'stopped_mock_capture.mat');
failed=run_hardware_hefting(failed_opts);FS=fi();
assert(~failed.completed&&~failed.prediction.accepted&&strcmp(failed.session.reason,'stopped_by_user'));
assert(FS.close_count==1&&isfile(failed_opts.output_file));
saved_failed=load(failed_opts.output_file,'session_result');
assert(isequaln(saved_failed.session_result,failed)&&~isempty(failed.session.raw_power));
expect_error(@()bpil_hefting_known_reference(failed_opts.output_file,'reference_train',known), ...
    'bpil:ReferenceCapture');
checks{end+1}='aborted captures retain their partial data and cannot become reference training examples';
assert(strcmp(prc_file_hash(original),original_hash));
checks{end+1}='the original frozen trained-model bytes are unchanged';

files={'run_hardware_hefting.m','src/bpil_hefting_hardware_profile.m', ...
    'src/bpil_hefting_loop.m','src/bpil_hefting_observation.m', ...
    'src/bpil_hefting_features.m','src/bpil_hefting_predict.m', ...
    'src/bpil_hefting_known_reference.m','tests/test_hardware_hefting.m', ...
    'tests/test_hardware_hefting_contracts.m','tests/helpers/bpil_mock_hefting_transport.m'};
hashes=cellfun(@(x)prc_file_hash(fullfile(root,x)),files,'UniformOutput',false);
manifest=table(string(files(:)),string(hashes(:)),'VariableNames',{'relative_path','sha256'});
writetable(manifest,fullfile(folder,'tested_source_manifest.csv'));
report=struct('pass',true,'checks',{checks},'check_count',numel(checks), ...
    'seconds',toc(started),'result_folder',folder,'complete_capture_file',file, ...
    'complete_capture_sha256',prc_file_hash(file),'original_model_sha256',original_hash, ...
    'factory_poll_calls',provider_poll_calls,'factory_close_calls',provider_close_calls, ...
    'source_manifest',manifest, ...
    'scope','Synthetic mock I/O contract and provenance tests only; no physical performance evidence');
save(fullfile(folder,'contract_test_report.mat'),'report');disp(report);
    function source=factory(now_fn,hardware)
        factory_calls=factory_calls+1;clock=now_fn;
        assert(isa(clock,'function_handle')&&strcmp(hardware.clock_id,H.clock_id));
        source=struct('poll',@factory_poll,'close',@factory_close);
    end
    function p=factory_poll(t)
        provider_poll_calls=provider_poll_calls+1;
        assert(abs(t-clock())<1e-12);p=power(t);
    end
    function factory_close()
        provider_close_calls=provider_close_calls+1;
    end
end

function H=profile()
H=bdclp_interface_defaults();H.simulation_only=false;H.calibrated=true;H.fixture_only=true;
H.calibration_id='synthetic_mock_only';H.firmware_id='synthetic_mock_only';
H.ee_mode='wrist';H.long_rod_verified=true;H.position_source_verified=true;
H.allow_torque_limit_write=false;H.sign=ones(1,4);H.zero_offset_rad=[0 0 0 pi];
H.model_qmin_rad=-2*ones(1,4);H.model_qmax_rad=2*ones(1,4);
H.wire_qmin_rad=H.model_qmin_rad+H.zero_offset_rad;
H.wire_qmax_rad=H.model_qmax_rad+H.zero_offset_rad;
H.feedback_t_semantics='joint_angle';H.probe_envelope_verified=true;
H.payload_fixture_verified=true;
end

function expect_error(callback,expected)
actual='';
try,callback();catch err,actual=err.identifier;end
assert(strcmp(actual,expected),'test:Contract','Expected %s, got %s.',expected,actual);
end

function T=forbidden_transport()
T=struct('now',@forbidden_io,'poll',@forbidden_io,'write',@forbidden_io, ...
    'wait',@forbidden_io,'close',@forbidden_io);
end

function varargout=forbidden_io(varargin) %#ok<STOUT,INUSD>
error('test:ForbiddenIO','Contract check attempted forbidden I/O.');
end
