function report=test_hardware_hefting_save(source_capture)
%TEST_HARDWARE_HEFTING_SAVE Focused compressed capture persistence tests.
% Reuses a previous synthetic full capture; opens no robot or meter.
root=fileparts(fileparts(mfilename('fullpath')));
addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'), ...
    fullfile(root,'tests','helpers'));
assert(isfile(source_capture),'test:SourceCapture','Supply the prior completed mock capture.');
folder=fullfile(root,'results',['hardware_hefting_save_v3_' ...
    char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
assert(~isfolder(folder));mkdir(folder);checks={};total=tic;
t=tic;A=load(source_capture,'session_result');old_read_s=toc(t);R=A.session_result;
assert(R.completed&&R.session.is_mock,'test:MockSource','Source must be a completed mock capture.');
compressed=fullfile(folder,'complete_mock_capture_compressed.mat');
t=tic;bpil_hefting_save(compressed,R);write_s=toc(t);
t=tic;B=load(compressed,'session_result');read_s=toc(t);
assert(isequaln(B.session_result,R),'test:Roundtrip','Compressed roundtrip changed capture fields.');
checks{end+1}='compressed writer preserves every capture field exactly';
known=[.15 .12 .005];ref=bpil_hefting_known_reference(compressed,'reference_train',known);
assert(isequaln(ref.obs,R.obs)&&isequal(ref.known_theta,known));
assert(strcmp(ref.record_hash,prc_file_hash(compressed))&&ref.capture_is_mock);
checks{end+1}='known-reference conversion reads the compressed capture and hashes the actual saved bytes';
before=prc_file_hash(compressed);identifier='';
try,bpil_hefting_save(compressed,R);catch err,identifier=err.identifier;end
assert(strcmp(identifier,'bpil:SessionExists')&&strcmp(before,prc_file_hash(compressed)));
assert(numel(dir(fullfile(folder,'*.mat')))==1,'test:Temporary','Writer left a temporary MAT file.');
checks{end+1}='existing capture is not overwritten and no temporary MAT file remains';

cfg=R.cfg;H=R.hardware;probe=R.probe;
[T,power,inspect]=bpil_mock_hefting_transport(H,cfg,probe);
factory_calls=0;poll_calls=0;close_calls=0;clock=[];
failed_file=fullfile(folder,'stopped_mock_capture_via_entry.mat');
opts=struct('mode','mock','cfg',cfg,'hardware',H,'probe',probe, ...
    'model_file',R.model_file,'eta',R.eta,'transport',T,'power_provider_factory',@factory, ...
    'stop_requested',@()T.now()>=.5,'output_file',failed_file);
failed=run_hardware_hefting(opts);S=inspect();F=load(failed_file,'session_result');
assert(~failed.completed&&~failed.prediction.accepted&&strcmp(failed.session.reason,'stopped_by_user'));
assert(isequaln(F.session_result,failed)&&~isempty(failed.session.raw_power));
assert(factory_calls==1&&poll_calls>0&&close_calls==1&&S.close_count==1);
checks{end+1}='entry point saves readable partial failure data and closes factory and transport once';
assert(any(strcmp(failed.source_files,'src/bpil_hefting_save.m')));
j=find(strcmp(failed.source_files,'src/bpil_hefting_save.m'));
assert(strcmp(failed.source_sha256{j},prc_file_hash(fullfile(root,'src','bpil_hefting_save.m'))));
checks{end+1}='saved source provenance includes the new capture writer';

files={'run_hardware_hefting.m','src/bpil_hefting_hardware_profile.m', ...
    'src/bpil_hefting_loop.m','src/bpil_hefting_observation.m', ...
    'src/bpil_hefting_features.m','src/bpil_hefting_predict.m', ...
    'src/bpil_hefting_known_reference.m','src/bpil_hefting_save.m', ...
    'tests/test_hardware_hefting.m','tests/test_hardware_hefting_contracts.m', ...
    'tests/test_hardware_hefting_save.m','tests/helpers/bpil_mock_hefting_transport.m'};
hashes=cellfun(@(x)prc_file_hash(fullfile(root,x)),files,'UniformOutput',false);
manifest=table(string(files(:)),string(hashes(:)),'VariableNames',{'relative_path','sha256'});
writetable(manifest,fullfile(folder,'tested_source_manifest.csv'));
old=dir(source_capture);new=dir(compressed);partial=dir(failed_file);
report=struct('pass',true,'checks',{checks},'check_count',numel(checks), ...
    'seconds',toc(total),'result_folder',folder,'source_capture',source_capture, ...
    'compressed_capture',compressed,'original_bytes',old.bytes,'compressed_bytes',new.bytes, ...
    'size_reduction_ratio',old.bytes/new.bytes,'old_read_s',old_read_s, ...
    'compressed_write_s',write_s,'compressed_read_s',read_s, ...
    'failed_capture_bytes',partial.bytes,'source_manifest',manifest, ...
    'scope','Persistence of synthetic mock captures; large-memory v7.3 fallback not exercised');
save(fullfile(folder,'save_test_report.mat'),'report');disp(report);
    function source=factory(now_fn,hardware)
        factory_calls=factory_calls+1;clock=now_fn;
        assert(strcmp(hardware.clock_id,H.clock_id));
        source=struct('poll',@poll,'close',@close_provider);
    end
    function p=poll(t)
        poll_calls=poll_calls+1;assert(abs(t-clock())<1e-12);p=power(t);
    end
    function close_provider(),close_calls=close_calls+1;end
end
