function report=payload_simulate_example(packageRoot,outputDir,trainObjectId,execute)
%PAYLOAD_SIMULATE_EXAMPLE Plan or generate one prescribed training probe.
%   payload_simulate_example(packageRoot) returns the simulation plan.
%   payload_simulate_example(packageRoot,newOutputDir,trainObjectId,true)
%   generates the probe and derives its features. Default object: 3000001.
%   Outputs include record validity and feature usability.
if nargin<1||isempty(packageRoot),packageRoot=fileparts(fileparts(mfilename('fullpath')));end
if nargin<2,outputDir='';end
if nargin<3||isempty(trainObjectId),trainObjectId=3000001;end
if nargin<4,execute=false;end
assert(islogical(execute)&&isscalar(execute),'payload:ExplicitExecution', ...
    'The fourth argument must be the logical value false or true.');
validateattributes(trainObjectId,{'numeric'},{'scalar','real','finite','integer','positive'});
packageRoot=canonical(packageRoot);
study=fullfile(packageRoot,'studies','pnn_large_training_20261031_v1');
snapshot=fullfile(study,'source_snapshot');
dataset=fullfile(packageRoot,'data','pnn','pnn_dataset.mat');
assert(isfile(dataset)&&isfile([dataset '.manifest.json']),'payload:Missing', ...
    'The compact PNN dataset and export manifest are required.');
export=jsondecode(fileread([dataset '.manifest.json']));listing=dir(dataset);
assert(strcmp(export.schema,'reviewer_pnn_export_v1')&&listing.bytes==export.export_bytes&& ...
    strcmp(payload_pnn_sha256(dataset),export.export_sha256),'payload:DataHash','The compact dataset differs from its manifest.');
% Load the configuration and object/trial identities.
S=load(dataset,'cfg','spec','provenance','object_manifest','trial_manifest');
assert(all(isfield(S,{'cfg','spec','provenance','object_manifest','trial_manifest'})), ...
    'payload:Schema','The export lacks configuration or identity tables.');
objects=S.object_manifest;manifest=S.trial_manifest;
oi=find(objects.object_id==trainObjectId);
assert(isscalar(oi)&&string(objects.split(oi))=="train",'payload:TrainingOnly', ...
    'Choose an object_id from the training split.');
ti=find(manifest.object_id==trainObjectId);
assert(isscalar(ti)&&string(manifest.split(ti))=="train"&&manifest.object_index(ti)==oi, ...
    'payload:TrainingIdentity','Expected one original training trial for this object.');
object=objects(oi,:);row=manifest(ti,:);
assert(row.trial_id>=1&&row.trial_id<=S.spec.counts(1),'payload:TrainingIdentity','Unexpected training trial ID.');
before=jsondecode(fileread(fullfile(study,'LOCKED_BEFORE_GENERATION.json')));
sourceManifest=fullfile(study,'source_manifest.csv');
assert(strcmp(before.source_manifest_sha256,payload_pnn_sha256(sourceManifest))&& ...
    strcmp(before.plan_signature,S.provenance.plan_signature),'payload:Provenance','Historical source or plan identity differs.');
sources=payload_pnn_read_csv(sourceManifest,'source_manifest');
sourceInfo=payload_verify_sources(sources,snapshot,packageRoot);
selected=sourceInfo.original_matlab_rows;
if isempty(outputDir)
    outputDir=fullfile(packageRoot,'outputs',sprintf('single_train_%d_%s', ...
        trainObjectId,char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))));
end
outputDir=canonical(outputDir);
for name={'studies','data','analysis','project','docs'}
    protected=canonical(fullfile(packageRoot,name{1}));
    assert(~within(outputDir,protected),'payload:Output','Choose a new output directory outside packaged inputs and code.');
end
assert(~isfolder(outputDir)&&~isfile(outputDir),'payload:Exists','Choose a new output directory.');
report=struct('schema','payload_single_train_generation_v1','mode','plan_only', ...
    'execution_requested',execute,'object_id',trainObjectId,'split','train', ...
    'historical_trial_id',row.trial_id,'condition',char(string(row.condition)), ...
    'theta_true_SI',[object.mass_kg object.cx_m object.cz_m], ...
    'sensor_seed',row.sensor_seed,'communication_seed',row.communication_seed, ...
    'nuisance_seed',row.nuisance_seed,'probe_id',S.spec.probe_id, ...
    'historical_plan_signature',S.provenance.plan_signature, ...
    'dataset_sha256',export.export_sha256,'source_manifest_sha256',before.source_manifest_sha256, ...
    'frozen_matlab_files_verified',sourceInfo.verified_files,'output_directory',outputDir, ...
    'planned_new_episodes',1,'planned_pose_count',8,'models_trained',0,'models_evaluated',0, ...
    'test_or_validation_objects_used',0,'required_execution_toolboxes', ...
    {{'Robotics System Toolbox','Optimization Toolbox'}}, ...
    'scope','Generates one prescribed training probe and derives features. Outputs include record validity and feature usability.');
if ~execute
    fprintf('SIMULATION PLAN: training object %d, trial %d, %s.\n', ...
        trainObjectId,row.trial_id,char(string(row.condition)));
    fprintf('Generate with: payload_simulate_example(packageRoot,newOutputDir,%d,true)\n',trainObjectId);
    return
end

% Run the prescribed configuration and seeds in a new output directory.
assert(exist('rigidBodyTree','class')==8&&exist('lsqnonlin','file')==2, ...
    'payload:Toolbox','Execution requires Robotics System Toolbox and Optimization Toolbox.');
priorPath=path;priorRng=rng;cleanup=onCleanup(@()restore_state(priorPath,priorRng)); %#ok<NASGU>
addpath(snapshot,fullfile(snapshot,'src'),fullfile(snapshot,'vendor','bdcl_v29'),'-begin');
required={'bpil_probe_library','pnn_conditions','pnn_expected_record','pnn_trial','pnn_features','pnn_checkpoint','psv_hash'};
for k=1:numel(required)
    assert(strcmpi(canonical(which(required{k})),canonical(fullfile(snapshot,'src',[required{k} '.m']))), ...
        'payload:Path','An unexpected %s shadows frozen source.',required{k});
end
cfg=S.cfg;cfg.root=snapshot; % Relocate only the non-numerical checkout root.
spec=S.spec;
spec.run_id=['payload_single_train_' num2str(trainObjectId) '_' char(java.util.UUID.randomUUID())];
probes=bpil_probe_library(cfg);probe=probes(spec.probe_index);
assert(strcmp(probe.id,spec.probe_id)&&isequal(size(probe.poses),[8 4]),'payload:Probe','The frozen probe differs.');
condition=pnn_conditions(cfg,probe,row.condition,row.nuisance_seed);
originalRow=row;row.object_index=1;
key=struct('schema','payload_single_train_generation_v1','historical_plan_signature',S.provenance.plan_signature, ...
    'historical_manifest_row',table2struct(originalRow),'object',table2struct(object), ...
    'condition',condition,'probe',probe,'source_manifest_sha256',before.source_manifest_sha256);
plan=struct('schema',key.schema,'spec',spec,'objects',object,'manifest',row, ...
    'probe',probe,'conditions',condition,'plan_signature',psv_hash(key));
expected=pnn_expected_record(plan,1);
assert(strcmp(expected.split,'train')&&expected.object_id==trainObjectId,'payload:TrainingOnly','Training identity changed.');
outputDir=payload_pnn_output_dir(packageRoot,outputDir,'single_train');
report.mode='executing';report.derived_plan_signature=plan.plan_signature;
report.derived_run_id=spec.run_id;report.created_utc=utc();
payload_pnn_write_json(fullfile(outputDir,'GENERATION_PLAN.json'),report);
trialFile=fullfile(outputDir,sprintf('example_trial_%06d.mat',expected.trial_id));
status=pnn_trial(trialFile,cfg,probe,condition,expected);
[saved,trialSeal]=pnn_checkpoint('read',trialFile);
F=pnn_features(cfg,saved.record.obs,S.spec);
featureFile=fullfile(outputDir,'example_features.mat');
pnn_checkpoint('write',featureFile,struct('features',F,'record_status',status, ...
    'source_trial_sha256',trialSeal.sha256,'expected',expected));
obs=saved.record.obs;
if isstruct(obs)&&all(isfield(obs,{'plateau_q','plateau_P','plateau_sd_P','stationary'}))&&isequal(size(obs.plateau_q),[8 4])
    pose=(1:8)';
    T=table(pose,obs.plateau_q(:,1),obs.plateau_q(:,2),obs.plateau_q(:,3),obs.plateau_q(:,4), ...
        obs.plateau_P(:),obs.plateau_sd_P(:),obs.stationary(:),'VariableNames', ...
        {'pose','q1_rad','q2_rad','q3_rad','q4_rad','mean_power_W','sd_power_W','stationary'});
    writetable(T,fullfile(outputDir,'observation_summary.csv'));
end
report.mode='complete';report.new_episodes_generated=1;report.record_status=status;
report.features_usable=F.usable;report.teacher_accepted=F.accepted;
report.feature_error=F.error;report.trial_sha256=trialSeal.sha256;
report.features_sha256=payload_pnn_sha256(featureFile);report.completed_utc=utc();
report.matlab_version=version;
report.complete_means='One probe attempt recorded; record_status and features_usable describe the output validity.';
payload_pnn_write_json(fullfile(outputDir,'EXAMPLE_COMPLETE.json'),report);
fprintf('Training-probe output: %s\n',outputDir);
end

function p=canonical(p),p=char(java.io.File(char(p)).getCanonicalPath());end
function yes=within(p,root),yes=strcmpi(p,root)||startsWith(lower(p),lower([root filesep]));end
function restore_state(previous,randomState),path(previous);rng(randomState);end
function value=utc(),value=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));end
