function [info,bundle]=pfl_run(mode,outdir,options)
%PFL_RUN Explicit manual entry; no background launch or boot registration.
% tinySmoke checks plumbing on old train/validation subsets, not performance.
% futurefull reuses only the original 12000/2000 train/validation episodes;
% it seals selection for a separately generated future confirmation panel.
if nargin<3,options=struct();end
if ~isfield(options,'source_run'),options.source_run='C:/new/results/pnn_large_training_20261031_v1';end
assert(ismember(char(mode),{'tinySmoke','futurefull'}),'pfl:Mode','Unknown mode.');
assert(~strcmp(mode,'futurefull')||(isfield(options,'full_run_authorized')&&isequal(options.full_run_authorized,true)), ...
    'pfl:FullNotAuthorized','Future full training is disabled without explicit later authorization.');
if strcmp(mode,'tinySmoke'),perCondition=4;else,perCondition=Inf;end
assert(~isfield(options,'per_condition')||isequal(options.per_condition,perCondition), ...
    'pfl:Subset','Use the prespecified 4-per-condition smoke or full data.');
assert(~strcmpi(canonical(outdir),canonical(options.source_run))&& ...
    ~startsWith([canonical(outdir) filesep],[canonical(options.source_run) filesep],IgnoreCase=true), ...
    'pfl:Destination','Never write into frozen source results.');
assert(~isfile(fullfile(outdir,'LOCKED_BEFORE_GENERATION.json'))&& ...
    ~isfile(fullfile(outdir,'FROZEN_PROTOCOL.txt'))&&~isfile(fullfile(outdir,'data_plan.mat')), ...
    'pfl:Destination','Existing generation/frozen run directories are read-only.');
if ~isfolder(outdir),mkdir(outdir);end
f=javaObject('java.io.RandomAccessFile',fullfile(outdir,'pfl_runner.lock'),'rw');ch=f.getChannel();
try,lk=ch.tryLock();catch err,ch.close();f.close();rethrow(err);end
if isempty(lk),ch.close();f.close();error('pfl:Busy','Another process owns this runner.');end
cleanup=onCleanup(@()release(lk,ch,f)); %#ok<NASGU>
[D,~,~,anchor,audit]=psx_read_frozen(options.source_run,perCondition);
spec=pfl_spec(anchor,mode);
if strcmp(mode,'futurefull'),spec.full_run_authorized=true;end
if isfield(options,'stop_after_epoch'),spec.stop_after_epoch=options.stop_after_epoch;end
if ~isfolder(outdir),mkdir(outdir);end
provenance=struct('schema','pfl_source_audit_v1','mode',char(mode),'audit',audit, ...
    'source_run',canonical(options.source_run),'dataset_hash',pnn_model_hash(D));
file=fullfile(outdir,'SOURCE_AUDIT.mat');
if pnn_model_exists(file)
    old=pnn_model_load(file);assert(isequaln(old.provenance,provenance),'pfl:ResumeMismatch','Source audit changed.');
else,pnn_model_atomic_save(file,struct('provenance',provenance));end
[info,bundle]=pfl_train(D,anchor,spec,outdir);
end
function p=canonical(p),p=char(javaObject('java.io.File',char(p)).getCanonicalPath());end
function release(l,c,f),try,l.release();catch,end;try,c.close();catch,end;try,f.close();catch,end;end
