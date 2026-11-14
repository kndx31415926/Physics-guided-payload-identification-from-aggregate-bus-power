function run_pca_job(runDir)
%RUN_PCA_JOB Train and audit locked convex affine comparators; no ODE calls.
% Invoke this function from the prepared run's source_snapshot directory.
runDir=canonical(runDir);snapshot=canonical(fileparts(mfilename('fullpath')));
assert(strcmpi(snapshot,canonical(fullfile(runDir,'source_snapshot'))), ...
    'pca:Snapshot','Invoke the frozen run_pca_job, not the working source copy.');
restoredefaultpath;addpath(snapshot,fullfile(snapshot,'src'),fullfile(snapshot,'vendor','bdcl_v29'));
maxNumCompThreads(1); %#ok<MAXNCT>
fh=java.io.RandomAccessFile(fullfile(runDir,'job.lock'),'rw');ch=fh.getChannel();
try,lk=ch.tryLock();catch err,ch.close();fh.close();rethrow(err);end
if isempty(lk),ch.close();fh.close();error('pca:Busy','Another process owns this audit.');end
cleanup=onCleanup(@()release(lk,ch,fh)); %#ok<NASGU>
diary(fullfile(runDir,'job.log'));dc=onCleanup(@()diary('off')); %#ok<NASGU>
phase='integrity';wall=tic;
try
    L=jsondecode(fileread(fullfile(runDir,'PREPARED_LOCK.json')));
    files={'inputs.mat','anchor_bundle.mat','source_manifest.csv','FROZEN_PROTOCOL.txt'};
    expected={L.inputs_sha256,L.anchor_sha256,L.source_manifest_sha256,L.protocol_sha256};
    for j=1:numel(files),assert(strcmp(prc_file_hash(fullfile(runDir,files{j})),expected{j}),'pca:Identity','Frozen audit input changed.');end
    manifest=readtable(fullfile(runDir,'source_manifest.csv'),'TextType','string');
    for j=1:height(manifest)
        assert(strcmp(prc_file_hash(fullfile(snapshot,manifest.relative_path(j))),manifest.sha256(j)),'pca:Source','Frozen source changed.');
    end
    I=pnn_checkpoint('read',fullfile(runDir,'inputs.mat'));A=pnn_checkpoint('read',fullfile(runDir,'anchor_bundle.mat'));
    assert(I.spec.posthoc_optimizer_audit&&~I.spec.new_confirmation&&~I.spec.selection_uses_test);
    for j=1:numel(I.sources)
        assert(strcmp(prc_file_hash(I.sources(j).path),I.sources(j).sha256),'pca:Source','External source changed.');
    end
    if isfile(fullfile(runDir,'COMPLETE.json'))
        done=jsondecode(fileread(fullfile(runDir,'COMPLETE.json')));
        for j=1:numel(done.outputs),assert(strcmp(prc_file_hash(done.outputs(j).path),done.outputs(j).sha256),'pca:Integrity','Completed audit changed.');end
        publish(runDir,'complete','complete','Existing completion verified.');return
    end
    phase='training';publish(runDir,'running',phase,'Training-only convex solves; evaluation panels remain unread.');
    [bundle,trainingReport]=pca_train(runDir,I,A.bundle);
    lock=jsondecode(fileread(fullfile(runDir,'MODEL_LOCK.json')));
    assert(~lock.selection_uses_test&&strcmp(lock.bundle_sha256,prc_file_hash(fullfile(runDir,'model_bundle.mat'))) ...
        &&strcmp(lock.bundle_content_hash,pnn_model_hash(bundle)),'pca:ModelLock','Model must be locked before evaluation.');
    assert(numel(bundle.methods)==16&&strcmp(pnn_model_hash(bundle.methods(1:14)),pnn_model_hash(A.bundle.methods)), ...
        'pca:Anchor','The original 14 methods must be unchanged.');
    options=struct('smoke_test',false,'bootstrap_replicates',I.spec.bootstrap_replicates, ...
        'bootstrap_seed',I.spec.bootstrap_seed,'bounds',I.fairSpec.bounds, ...
        'pairs',{{'nonlinear_fixed','affine_convex_fixed';'nonlinear_fixed','affine_convex_selected';'nonlinear_fixed','affine_fixed'}});
    panels={'original',I.spec.original_evaluation,2000,500,4;'pbd',I.spec.pbd_evaluation,156,12,13};
    evaluationAudit=struct([]);evaluationInfo=cell(2,1);
    for panel=1:size(panels,1)
        phase=[panels{panel,1} '_evaluation'];publish(runDir,'running',phase,'Locked post hoc comparison on previously inspected complete object panels.');
        sourceFolder=panels{panel,2};sourceComplete=jsondecode(fileread(fullfile(sourceFolder,'EVALUATION_COMPLETE.json')));
        [prior,sourceSeal]=pca_read_sealed(fullfile(sourceFolder,'evaluation_matrices.mat'));
        assert(strcmp(sourceComplete.identity_hash,prior.identity_hash)&&~sourceComplete.smoke_only, ...
            'pca:EvaluationSource','Evaluation source identity mismatch.');
        D=prior.data;conditions=unique(string(D.condition),'stable');objects=unique(D.object_id);
        assert(size(D.theta,1)==panels{panel,3}&&numel(objects)==panels{panel,4}&&numel(conditions)==panels{panel,5}, ...
            'pca:Panel','Expected complete original/PBD panel.');
        assert(all(string(D.split)=="test")&&all(ismember(string(prior.method_names),string({A.bundle.methods.name}))), ...
            'pca:Panel','Unexpected source methods or split.');
        for c=1:numel(conditions)
            assert(isequal(sort(D.object_id(string(D.condition)==conditions(c))),sort(objects)), ...
                'pca:ObjectUnit','Every condition must contain every planned object exactly once.');
        end
        target=fullfile(runDir,[panels{panel,1} '_evaluation']);evaluationInfo{panel}=psx_evaluate(D,bundle,options,target);
        fresh=pnn_checkpoint('read',fullfile(target,'evaluation_matrices.mat'));maxDifference=0;
        for j=1:numel(prior.method_names)
            ix=find(string(fresh.method_names)==string(prior.method_names(j)));assert(isscalar(ix));
            before=prior.raw_predictions(:,:,j);after=fresh.raw_predictions(:,:,ix);
            assert(isequal(isnan(before),isnan(after))&&isequal(isinf(before),isinf(after)), ...
                'pca:OldPrediction','Original failure masks changed.');
            finite=isfinite(before)&isfinite(after);difference=0;if any(finite,'all'),difference=max(abs(before(finite)-after(finite)));end
            maxDifference=max(maxDifference,difference);
            assert(difference<=1e-12&&isequal(prior.accepted(:,j),fresh.accepted(:,ix)) ...
                &&isequal(prior.bounds_hit(:,j),fresh.bounds_hit(:,ix)), ...
                'pca:OldPrediction','Original predictions or acceptance/bounds masks changed.');
        end
        paired_object_deltas(fresh,options.pairs,fullfile(target,'paired_object_deltas.csv'));
        r=struct('panel',panels{panel,1},'source_sha256',sourceSeal.sha256, ...
            'dataset_hash',pnn_model_hash(D),'rows',size(D.theta,1),'objects',numel(objects),'conditions',numel(conditions), ...
            'old_method_prediction_max_absolute_difference',maxDifference,'old_method_masks_unchanged',true, ...
            'bootstrap_unit','Complete independent object within each condition; identical object ordering and resampling seed across conditions.', ...
            'posthoc_descriptive_only',true,'new_confirmation',false);
        if isempty(evaluationAudit),evaluationAudit=r;else,evaluationAudit(end+1)=r;end %#ok<AGROW>
    end
    prc_write_json(fullfile(runDir,'EVALUATION_AUDIT.json'),struct('panels',evaluationAudit,'model_locked_before_test_read',true, ...
        'new_confirmation',false,'inference','Descriptive paired bootstrap, with no multiplicity-adjusted superiority claim.'));
    fixedFiles={'inputs.mat','inputs.mat.sha256.json','anchor_bundle.mat','anchor_bundle.mat.sha256.json', ...
        'source_manifest.csv','PREPARED_LOCK.json','FROZEN_PROTOCOL.txt','spec.json','model_bundle.mat', ...
        'model_bundle.mat.sha256.json','MODEL_LOCK.json','EVALUATION_AUDIT.json'};
    outputFiles=cellfun(@(f)fullfile(runDir,f),fixedFiles,'UniformOutput',false);
    listing=dir(fullfile(runDir,'training','*'));listing=listing(~[listing.isdir]);
    for j=1:numel(listing),outputFiles{end+1}=fullfile(listing(j).folder,listing(j).name);end %#ok<AGROW>
    for j=1:numel(evaluationInfo)
        info=evaluationInfo{j};outputFiles=[outputFiles {info.outputs.path}]; %#ok<AGROW>
        folder=fullfile(runDir,[panels{j,1} '_evaluation']);
        outputFiles=[outputFiles {fullfile(folder,'EVALUATION_COMPLETE.json'),fullfile(folder,'paired_object_deltas.csv')}]; %#ok<AGROW>
    end
    outputs=struct('path',{},'sha256',{});
    for j=1:numel(outputFiles),outputs(j)=struct('path',outputFiles{j},'sha256',prc_file_hash(outputFiles{j}));end
    prc_write_json(fullfile(runDir,'COMPLETE.json'),struct('schema','pca_posthoc_complete_v1','completed_utc',pnn_utc(), ...
        'wall_s_this_invocation',toc(wall),'training_objects',trainingReport.train_objects, ...
        'validation_objects',trainingReport.validation_objects,'new_confirmatory_test_objects',0, ...
        'new_simulations',0,'posthoc_optimizer_audit',true,'new_confirmation',false,'outputs',outputs));
    publish(runDir,'complete','complete','Convex optimizer audit and both descriptive evaluations complete.');
catch err
    folder=fullfile(runDir,'failures');if ~isfolder(folder),mkdir(folder);end
    id=char(java.util.UUID.randomUUID());
    prc_write_json(fullfile(folder,['failure_' id '.json']),struct('phase',phase,'identifier',err.identifier, ...
        'message',err.message,'stack',err.stack,'utc',pnn_utc(),'automatic_retry',false));
    publish(runDir,'failed',phase,err.message);rethrow(err)
end
end

function paired_object_deltas(E,pairs,file)
rows=cell(size(pairs,1),1);D=E.data;n=size(D.theta,1);
for k=1:size(pairs,1)
    a=find(string(E.method_names)==string(pairs{k,1}));b=find(string(E.method_names)==string(pairs{k,2}));
    P=E.raw_predictions(:,:,a);Q=E.raw_predictions(:,:,b);finite=all(isfinite(P),2)&all(isfinite(Q),2);
    mass=(abs(P(:,1)-D.theta(:,1))-abs(Q(:,1)-D.theta(:,1)))*1000;
    com=(sqrt(sum((P(:,2:3)-D.theta(:,2:3)).^2,2))-sqrt(sum((Q(:,2:3)-D.theta(:,2:3)).^2,2)))*1000;
    rows{k}=table(D.trial_id,D.object_id,string(D.condition),repmat(string(pairs{k,1}),n,1), ...
        repmat(string(pairs{k,2}),n,1),finite,E.accepted(:,a),E.accepted(:,b),mass,com, ...
        'VariableNames',{'trial_id','object_id','condition','method','baseline','paired_finite', ...
        'method_accepted','baseline_accepted','delta_mass_abs_error_g','delta_planar_com_distance_mm'});
end
T=vertcat(rows{:});tmp=[file '.' char(java.util.UUID.randomUUID()) '.tmp'];writetable(T,tmp,'FileType','text');
if isfile(file),assert(strcmp(prc_file_hash(file),prc_file_hash(tmp)),'pca:Integrity','Object deltas changed.');delete(tmp);
else,[ok,msg]=movefile(tmp,file);assert(ok,'pca:Write','%s',msg);end
end
function publish(runDir,state,phase,message)
prc_write_json(fullfile(runDir,'status.json'),struct('state',state,'phase',phase,'message',message,'updated_utc',pnn_utc()));
fprintf('%s | %s | %s\n',state,phase,message);
end
function path=canonical(path),path=char(java.io.File(char(path)).getCanonicalPath());end
function release(lk,ch,fh),lk.release();ch.close();fh.close();end
