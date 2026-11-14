function report=psx_test_evaluation(outdir)
%PSX_TEST_EVALUATION Cheap contracts; no plant, real data or scientific result.
root=fileparts(fileparts(mfilename('fullpath')));addpath(root,fullfile(root,'src'));
if nargin<1,outdir=fullfile(root,'tmp',['psx_eval_test_' char(java.util.UUID.randomUUID())]);end
assert(~isfolder(outdir),'psx:TestDirectory','Use a new test directory.');mkdir(outdir);
nobj=4;n=2*nobj;
D=struct('schema','pnn_dataset_v1','base',zeros(n,3),'theta',zeros(n,3), ...
    'X13',zeros(n,13),'Xaug',zeros(n,52),'usable',true(n,1),'accepted',true(n,1), ...
    'physics8accepted',true(n,1),'physics8usable',true(n,1),'object_id',repelem((1:nobj).',2), ...
    'trial_id',(1:n).','split',repmat("test",n,1),'condition',repmat(["severity_zero";"severity_high"],nobj,1));
D.theta=[.1+.001*D.object_id,repmat(.09,n,1),zeros(n,1)];
D.base=D.theta+[.001 .002 0];D.base(3,:)=D.theta(3,:)+[.009 .006 0];D.base(4,1)=.4;
D.accepted(3)=false;D.physics8=D.theta;D.physics8(1,:)=NaN;D.physics8(2,1)=Inf;
model=pnn_ridge_fit(D.X13,zeros(n,3),.001,'linear');
methods(1)=struct('name','ridge13','kind','ridge','input','X13','model',model,'selection',struct());
methods(2)=struct('name','physics8','kind','physics8','input','','model',[],'selection',struct());
bundle=struct('schema','pnn_bundle_v1','methods',methods,'primary_method','ridge13');
o=struct('smoke_test',true,'bootstrap_replicates',50,'bootstrap_seed',269901, ...
    'bounds',[.06 .25;.04 .20;-.025 .025],'pairs',{{'physics8','ridge13'}});
evaldir=fullfile(outdir,'evaluation');info=psx_evaluate(D,bundle,o,evaldir);
assert(info.smoke_only&&info.planned_trials==8&&info.unique_objects==4,'psx:Test','Wrong smoke denominator.');
S=readtable(fullfile(evaldir,'summary.csv'),'TextType','string');
T=readtable(fullfile(evaldir,'paired_intervals.csv'),'TextType','string');
R=readtable(fullfile(evaldir,'predictions.csv'),'TextType','string');
raw=S(S.method=="physics8"&S.postprocessing=="raw",:);clip=S(S.method=="physics8"&S.postprocessing=="common_clip",:);
assert(all(raw.planned_n==4)&&all(raw.finite_n==3)&&all(raw.failed_n==1)&&isequal(raw.finite_n,clip.finite_n), ...
    'psx:Test','Failed predictions left the denominator or clipping repaired them.');
row=S(S.method=="ridge13"&S.condition=="severity_zero"&S.postprocessing=="raw",:);
assert(row.finite_n==4&&row.accepted_n==3&&row.finite_rejected_n==1&&abs(row.mass_mae_g-3)<1e-9&& ...
    abs(row.accepted_mass_mae_g-1)<1e-9,'psx:Test','Finite rejected error was incorrectly excluded.');
assert(all(T.planned_n==4)&&all(T.paired_n==3)&&all(isnan(T.ci95_lower))&& ...
    all(isnan(T.ci95_upper))&&all(T.bootstrap_replicates==0),'psx:Test','Smoke produced scientific inference or wrong paired denominator.');
badraw=R(R.method=="physics8"&R.postprocessing=="raw"&~R.finite,:);
badclip=R(R.method=="physics8"&R.postprocessing=="common_clip"&~R.finite,:);
assert(height(badraw)==2&&isequal(badraw.trial_id,badclip.trial_id),'psx:Test','Nonfinite prediction identity changed.');
before=prc_file_hash(fullfile(evaldir,'EVALUATION_COMPLETE.json'));again=psx_evaluate(D,bundle,o,evaldir);
assert(strcmp(again.identity_hash,info.identity_hash)&&strcmp(before,prc_file_hash(fullfile(evaldir,'EVALUATION_COMPLETE.json'))), ...
    'psx:Test','Completed evaluation was rewritten.');
altered=D;altered.theta(1,1)=altered.theta(1,1)+.001;assert_rejected(@()psx_evaluate(altered,bundle,o,evaldir),'psx:EvalIdentity');
other=o;other.bootstrap_seed=other.bootstrap_seed+1;assert_rejected(@()psx_evaluate(D,bundle,other,evaldir),'psx:EvalIdentity');
changed=bundle;changed.methods(1).model.intercept(1)=.1;assert_rejected(@()psx_evaluate(D,changed,o,evaldir),'psx:EvalIdentity');
repeated=D;repeated.object_id(3)=repeated.object_id(1);assert_rejected(@()psx_evaluate(repeated,bundle,o,fullfile(outdir,'invalid')),'psx:RepeatedObject');
% Resume after a derived table exists but before the completion marker.
resume_dir=fullfile(outdir,'resume');mkdir(resume_dir);
psx_evaluate(D,bundle,o,resume_dir);completion=fullfile(resume_dir,'EVALUATION_COMPLETE.json');
movefile(completion,[completion '.preserved_for_test']);
old_table=prc_file_hash(fullfile(resume_dir,'summary.csv'));resumed=psx_evaluate(D,bundle,o,resume_dir);
assert(strcmp(resumed.identity_hash,info.identity_hash)&&strcmp(old_table,prc_file_hash(fullfile(resume_dir,'summary.csv'))), ...
    'psx:Test','Interrupted derived-output regeneration changed predictions.');
% Internal software fixtures exercise the production bootstrap branch. These
% deliberately synthetic constant errors are NOT payload experiments or
% scientific inference, even though that branch has smoke_test=false.
fixture=D;fixture.base=fixture.theta+[.001 .002 0];fixture.physics8=fixture.theta;
fixture.accepted(:)=true;fixture.physics8accepted(:)=true;fixture.physics8usable(:)=true;
fixture.schema='psx_synthetic_software_fixture_NOT_SCIENTIFIC';
bootstrap_options=o;bootstrap_options.smoke_test=false;
constant_dir=fullfile(outdir,'software_fixture_constant_bootstrap');
psx_evaluate(fixture,bundle,bootstrap_options,constant_dir);
B=readtable(fullfile(constant_dir,'paired_intervals.csv'),'TextType','string');
mass=B.metric=="mass_mae_g";com=B.metric=="planar_com_mean_distance_mm";
assert(all(B.paired_n==4)&&all(B.bootstrap_replicates==50)&& ...
    all(abs(B.delta_mean(mass)+1)<1e-9)&&all(abs(B.ci95_lower(mass)+1)<1e-9)&&all(abs(B.ci95_upper(mass)+1)<1e-9)&& ...
    all(abs(B.delta_mean(com)+2)<1e-9)&&all(abs(B.ci95_lower(com)+2)<1e-9)&&all(abs(B.ci95_upper(com)+2)<1e-9), ...
    'psx:Test','Constant-difference bootstrap did not reproduce exact intervals.');
fixture.physics8(3:end,:)=NaN;
singleton_dir=fullfile(outdir,'software_fixture_single_pair_bootstrap');
psx_evaluate(fixture,bundle,bootstrap_options,singleton_dir);
B=readtable(fullfile(singleton_dir,'paired_intervals.csv'),'TextType','string');
assert(all(B.paired_n==1)&&all(isfinite(B.ci95_lower))&&all(abs(B.ci95_lower-B.delta_mean)<1e-9)&& ...
    all(abs(B.ci95_upper-B.delta_mean)<1e-9),'psx:Test','Singleton pair resampling changed matrix orientation.');
fixture.physics8(:)=NaN;
failed_dir=fullfile(outdir,'software_fixture_no_pairs_bootstrap');
psx_evaluate(fixture,bundle,bootstrap_options,failed_dir);
B=readtable(fullfile(failed_dir,'paired_intervals.csv'),'TextType','string');
assert(all(B.planned_n==4)&&all(B.paired_n==0)&&all(isnan(B.delta_mean))&& ...
    all(isnan(B.ci95_lower))&&all(isnan(B.ci95_upper)),'psx:Test','No-pair fixture fabricated an interval.');
zero=o;zero.bootstrap_replicates=0;zero_dir=fullfile(outdir,'smoke_zero_bootstrap');
zero_info=psx_evaluate(D,bundle,zero,zero_dir);assert(zero_info.smoke_only,'psx:Test','Zero-bootstrap smoke rejected.');
zero.smoke_test=false;assert_rejected(@()psx_evaluate(D,bundle,zero,fullfile(outdir,'invalid_formal_bootstrap')),'psx:EvalOptions');
report=struct('passed',true,'smoke_only',true,'scientific_performance_run',false,'groups',14, ...
    'bootstrap_software_fixtures_passed',true,'directory',outdir,'completed_utc',pnn_utc());
prc_write_json(fullfile(outdir,'test_report.json'),report);disp(report);
end
function assert_rejected(action,identifier)
caught=false;try,action();catch err,caught=strcmp(err.identifier,identifier);end
assert(caught,'psx:Test','Expected rejection: %s',identifier);
end
