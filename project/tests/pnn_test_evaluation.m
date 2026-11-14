function report=pnn_test_evaluation(outdir)
% Synthetic evaluation contracts, without expensive plant simulation.
root=fileparts(fileparts(mfilename('fullpath')));addpath(root,fullfile(root,'src'));
if nargin<1,outdir=fullfile(root,'tmp',['pnn_evaluation_smoke_' char(java.util.UUID.randomUUID())]);end
mkdir(outdir);nobj=12;n=nobj*4;
D=struct('schema','pnn_dataset_v1','plan_signature','synthetic_evaluation_only', ...
    'base',zeros(n,3),'theta',zeros(n,3),'X13',zeros(n,13),'Xaug',zeros(n,52), ...
    'usable',true(n,1),'accepted',true(n,1),'physics8accepted',true(n,1), ...
    'physics8usable',true(n,1),'object_id',repelem((1:nobj).',4), ...
    'trial_id',(1:n).','split',repmat("test",n,1), ...
    'condition',repmat(["nominal";"mechanical";"electrical";"combined"],nobj,1));
D.theta=[.1+.001*D.object_id,.09+.0001*D.object_id,zeros(n,1)];
D.base=D.theta+[.001 .002 0];D.physics8=D.theta;
spec=struct('bounds',[.06 .25;.04 .20;-.025 .025],'bootstrap_seed',1469991, ...
    'bootstrap_replicates',250,'scope','synthetic evaluator test only');
names={'ridge13','ridgeAug','interactionRidge','ridgeSkipNN13','physics6','physics8'};
methods=struct('name',{},'kind',{},'input',{},'model',{},'selection',{});
for k=1:numel(names)
    kind='ridge';input='X13';model=pnn_ridge_fit(D.X13,zeros(n,3),.001,'linear');
    if k==4,model=pnn_ridge_fit(D.X13,repmat([-.0005 -.001 0],n,1),.001,'linear');end
    if k==5,kind='physics6';model=[];input='';end
    if k==6,kind='physics8';model=[];input='';end
    methods(end+1)=struct('name',names{k},'kind',kind,'input',input,'model',model,'selection',struct()); %#ok<AGROW>
end
bundle=struct('schema','pnn_bundle_v1','methods',methods,'primary_method','ridgeSkipNN13','bounds',spec.bounds);
model_file=fullfile(outdir,'model_bundle.mat');save(model_file,'bundle');
lock=struct('bundle_path',model_file,'bundle_sha256',prc_file_hash(model_file), ...
    'plan_signature',D.plan_signature,'selection_uses_test',false);
prc_write_json(fullfile(outdir,'MODEL_LOCK.json'),lock);
info=pnn_evaluate(D,spec,outdir);
assert(info.all_endpoint_superiority_supported&&info.all_three_ridge_superiority_supported,'pnn:Test','Known strict improvement missed.');
S=readtable(fullfile(outdir,'summary.csv'),'TextType','string');
row=S.method=="ridgeSkipNN13"&S.postprocessing=="raw";
assert(all(abs(S.mass_mae_g(row)-.5)<1e-10)&&all(abs(S.planar_com_mean_distance_mm(row)-1)<1e-10));
same=pnn_evaluate(D,spec,outdir);assert(strcmp(same.dataset_hash,info.dataset_hash));
altered=D;altered.theta(1,1)=altered.theta(1,1)+.0001;caught=false;
try,pnn_evaluate(altered,spec,outdir);catch err,caught=strcmp(err.identifier,'pnn:EvalIdentity');end
assert(caught,'pnn:Test','Dataset changes must not silently reuse evaluation.');
failure_dir=fullfile(outdir,'nonfinite');mkdir(failure_dir);save(fullfile(failure_dir,'model_bundle.mat'),'bundle');
lock.bundle_path=fullfile(failure_dir,'model_bundle.mat');lock.bundle_sha256=prc_file_hash(lock.bundle_path);
prc_write_json(fullfile(failure_dir,'MODEL_LOCK.json'),lock);
bad=D;bad.physics8(1,:)=NaN;bad.physics8(2,1)=Inf;
pnn_evaluate(bad,spec,failure_dir);S=readtable(fullfile(failure_dir,'summary.csv'),'TextType','string');
raw=S(S.method=="physics8"&S.postprocessing=="raw",:);
clip=S(S.method=="physics8"&S.postprocessing=="common_clip",:);
assert(isequal(raw.finite_n,clip.finite_n)&&sum(raw.failed_n)==2,'pnn:Test','Clipping repaired a failure.');
report=struct('passed',true,'groups',6,'directory',outdir,'completed_utc',pnn_utc());
prc_write_json(fullfile(outdir,'test_report.json'),report);disp(report);
end
