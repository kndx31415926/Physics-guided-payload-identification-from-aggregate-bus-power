function runDir=prepare_pca_run(name)
%PREPARE_PCA_RUN Freeze an optimizer audit; does not train, evaluate or simulate.
if nargin<1,name='pca_convex_audit_20261111_v1';end
root=fileparts(mfilename('fullpath'));assert(~isempty(regexp(name,'^pca_[A-Za-z0-9_]+$','once')));
runDir=fullfile(root,'results',name);assert(~isfolder(runDir),'pca:Exists','Use a new audit identity.');
parent=fullfile(root,'results','psx_supplement_formal_20261106_v1');snapshot=fullfile(parent,'source_snapshot');
addpath(snapshot,fullfile(snapshot,'src'),fullfile(snapshot,'vendor','bdcl_v29'));addpath(fullfile(root,'src'));
L=jsondecode(fileread(fullfile(parent,'PREPARED_LOCK.json')));
assert(strcmp(prc_file_hash(fullfile(parent,'configuration.mat')),L.configuration_sha256));
assert(strcmp(prc_file_hash(fullfile(parent,'source_manifest.csv')),L.source_manifest_sha256));
manifest=readtable(fullfile(parent,'source_manifest.csv'),'TextType','string');
for j=1:height(manifest),assert(strcmp(prc_file_hash(fullfile(snapshot,manifest.relative_path(j))),manifest.sha256(j)));end
P=load(fullfile(parent,'configuration.mat'),'spec');trainingRun=P.spec.source_run;
[old,anchorAudit]=pca_read_sealed(fullfile(parent,'combined_bundle.mat'));
modelLock=jsondecode(fileread(fullfile(parent,'MODEL_LOCK.json')));
assert(strcmp(anchorAudit.sha256,modelLock.bundle_sha256)&&~modelLock.selection_uses_test);
[fair,fairAudit]=pca_read_sealed(fullfile(parent,'matched_training','model_bundle.mat'),true);
fairSpec=fair.bundle.spec;
assert(strcmp(fairSpec.input,'X13')&&isequal(fairSpec.linear_lambdas,[1e-7 1e-6 1e-5 1e-4 1e-3 1e-2]) ...
    &&fairSpec.fixed_lambda==1e-4&&fairSpec.fixed_alpha==.5&&numel(fairSpec.network_seeds)==3 ...
    &&numel(old.bundle.methods)==14,'pca:MatchedContract','The original matched affine contract changed.');
spec=struct('schema','pca_posthoc_convex_audit_v1','run_id',name,'training_run',trainingRun, ...
    'parent_run',parent,'matched_training',fullfile(parent,'matched_training'), ...
    'original_evaluation',fullfile(parent,'original_evaluation'), ...
    'pbd_evaluation',fullfile(root,'results','pbd_exploration_20261110_v1','snapshots','snapshot_012','evaluation'), ...
    'method_names',{{'affine_convex_fixed','affine_convex_selected'}}, ...
    'optimizer',struct('max_iterations',200,'max_backtracks',60,'gradient_tolerance',1e-7, ...
        'decrement_relative_tolerance',1e-11,'initial_damping',1e-12,'maximum_damping',1e-3, ...
        'armijo',1e-4,'difference_step',2e-5,'gradient_check_tolerance',2e-6, ...
        'hessian_check_tolerance',2e-5,'objective_agreement_tolerance',1e-9, ...
        'prediction_agreement_tolerance',1e-7,'export_prediction_tolerance',1e-7), ...
    'bootstrap_replicates',5000,'bootstrap_seed',32111101,'automatic_start',false, ...
    'posthoc_optimizer_audit',true,'new_confirmation',false,'selection_uses_test',false, ...
    'source_anchor_sha256',anchorAudit.sha256,'source_matched_sha256',fairAudit.sha256,'created_utc',pnn_utc());
sources=struct('path',{},'sha256',{});
sourceFiles={fullfile(parent,'MODEL_LOCK.json'),fullfile(trainingRun,'configuration.mat'), ...
    fullfile(trainingRun,'input_manifest.csv'),fullfile(trainingRun,'MODEL_LOCK.json'), ...
    fullfile(spec.original_evaluation,'EVALUATION_COMPLETE.json'), ...
    fullfile(spec.original_evaluation,'evaluation_matrices.mat'), ...
    fullfile(spec.pbd_evaluation,'EVALUATION_COMPLETE.json'),fullfile(spec.pbd_evaluation,'evaluation_matrices.mat')};
for j=1:numel(sourceFiles),sources(j)=struct('path',sourceFiles{j},'sha256',prc_file_hash(sourceFiles{j}));end
for k=1:numel(fairSpec.linear_lambdas)
    for j=1:numel(fairSpec.network_seeds)
        path=fullfile(spec.matched_training,'candidates',sprintf('affine_c%02d_seed%d.mat',k,fairSpec.network_seeds(j)));
        [~,audit]=pca_read_sealed(path,true);
        sources(end+1)=struct('path',path,'sha256',audit.sha256); %#ok<AGROW>
        sources(end+1)=struct('path',audit.sealed_path,'sha256',audit.sha256); %#ok<AGROW>
        seal=[audit.sealed_path '.sha256.json'];sources(end+1)=struct('path',seal,'sha256',prc_file_hash(seal)); %#ok<AGROW>
    end
end
mkdir(runDir);destination=fullfile(runDir,'source_snapshot');copyfile(snapshot,destination);
files={'prepare_pca_run.m','run_pca_job.m'};
for j=1:numel(files),copyfile(fullfile(root,files{j}),fullfile(destination,files{j}));end
files={'pca_objective.m','pca_solve_affine.m','pca_read_sealed.m','pca_gradient_check.m','pca_train.m'};
for j=1:numel(files),copyfile(fullfile(root,'src',files{j}),fullfile(destination,'src',files{j}));end
copyfile(fullfile(root,'docs','pca_convex_audit_protocol_20261111.txt'),fullfile(runDir,'FROZEN_PROTOCOL.txt'));
pnn_checkpoint('write',fullfile(runDir,'inputs.mat'),struct('spec',spec,'fairSpec',fairSpec,'sources',sources));
pnn_checkpoint('write',fullfile(runDir,'anchor_bundle.mat'),struct('bundle',old.bundle));
prc_write_json(fullfile(runDir,'spec.json'),spec);
listing=dir(fullfile(destination,'**','*'));listing=listing(~[listing.isdir]);relative_path=strings(numel(listing),1);sha256=relative_path;
for j=1:numel(listing)
    f=fullfile(listing(j).folder,listing(j).name);relative_path(j)=string(f(numel(destination)+2:end));sha256(j)=prc_file_hash(f);
end
writetable(table(relative_path,sha256),fullfile(runDir,'source_manifest.csv'));
lock=struct('inputs_sha256',prc_file_hash(fullfile(runDir,'inputs.mat')), ...
    'anchor_sha256',prc_file_hash(fullfile(runDir,'anchor_bundle.mat')), ...
    'source_manifest_sha256',prc_file_hash(fullfile(runDir,'source_manifest.csv')), ...
    'protocol_sha256',prc_file_hash(fullfile(runDir,'FROZEN_PROTOCOL.txt')),'prepared_utc',pnn_utc());
prc_write_json(fullfile(runDir,'PREPARED_LOCK.json'),lock);
prc_write_json(fullfile(runDir,'status.json'),struct('state','prepared','updated_utc',pnn_utc()));
fprintf('Prepared post hoc convex optimizer audit: %s\n',runDir);
end
