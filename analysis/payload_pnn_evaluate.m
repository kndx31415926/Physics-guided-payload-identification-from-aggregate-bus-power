function report=payload_pnn_evaluate(packageRoot,outputDir)
% Evaluate saved estimators with 5000 paired-object bootstrap samples.
% Reads compact features and writes results to a new output directory.
% payload_pnn_evaluate('<package>','<new writable directory>')
if nargin<1||isempty(packageRoot),packageRoot=fileparts(fileparts(mfilename('fullpath')));end
if nargin<2,outputDir='';end
[S,paths,restorePath]=payload_pnn_setup(packageRoot); %#ok<ASGLU>
assert(S.spec.bootstrap_replicates==5000,'payload:Bootstrap','Expected the original 5000 bootstrap replicates.');
assert(isfile(fullfile(paths.study,'paired_intervals.csv'))&&isfile(fullfile(paths.study,'primary_comparison.json')), ...
    'payload:Missing','Full evaluation requires original paired_intervals.csv and primary_comparison.json.');
for name={'paired_intervals.csv','primary_comparison.json'}
    found=false;
    for k=1:numel(S.evaluation.outputs)
        parts=regexp(strrep(char(S.evaluation.outputs(k).path),'\','/'),'/','split');
        if strcmp(parts{end},name{1})
            assert(strcmp(payload_pnn_sha256(fullfile(paths.study,name{1})),S.evaluation.outputs(k).sha256), ...
                'payload:ReferenceHash','Changed reference %s.',name{1});found=true;
        end
    end
    assert(found,'payload:ReferenceHash','No historical output hash for %s.',name{1});
end
outputDir=payload_pnn_output_dir(paths.root,outputDir,'pnn_evaluation');
for name={'model_bundle.mat','MODEL_LOCK.json'}
    [ok,msg]=copyfile(fullfile(paths.study,name{1}),fullfile(outputDir,name{1}));assert(ok,'payload:Copy','%s',msg);
end
info=pnn_evaluate(S.test,S.spec,outputDir);
files={'predictions.csv','summary.csv','paired_intervals.csv'};
schemas={'predictions','summary','paired_intervals'};
keys={{'method','postprocessing','trial_id'},{'method','condition','postprocessing'}, ...
    {'method','baseline','condition','postprocessing','metric'}};
comparison=struct([]);
for k=1:numel(files)
    actual=payload_pnn_read_csv(fullfile(outputDir,files{k}),schemas{k});
    reference=payload_pnn_read_csv(fullfile(paths.study,files{k}),schemas{k});
    row=compare_tables(actual,reference,keys{k});row.file=files{k};
    if isempty(comparison),comparison=row;else,comparison(end+1)=row;end %#ok<AGROW>
end
actual=jsondecode(fileread(fullfile(outputDir,'primary_comparison.json')));
reference=jsondecode(fileread(fullfile(paths.study,'primary_comparison.json')));
conclusionEqual=isequaln(actual,reference);
report=struct('schema','payload_pnn_evaluation_v1','release',version('-release'), ...
    'source_model_sha256',S.lock.bundle_sha256,'export_sha256',S.export_manifest.export_sha256, ...
    'value_hashes',S.value_hashes,'planned_trials',8000,'independent_test_objects',2000,'methods',9, ...
    'bootstrap_replicates',S.spec.bootstrap_replicates,'bootstrap_seed',S.spec.bootstrap_seed, ...
    'raw_trajectories_loaded',0,'models_trained',0,'new_simulations',0,'tables',comparison, ...
    'primary_comparison_exact',conclusionEqual,'passed',all([comparison.passed])&&conclusionEqual, ...
    'evaluation',info);
payload_pnn_write_json(fullfile(outputDir,'PNN_FULL_EVALUATION_ANALYSIS.json'),report);
assert(report.passed,'payload:EvaluationMismatch','Evaluation differs. Inspect %s.',outputDir);
fprintf('PNN_FULL_EVALUATION_PAYLOAD_COMPLETE: numerical summaries and paired intervals match the reference.\n%s\n',outputDir);
end
function out=compare_tables(a,b,keys)
assert(isequal(a.Properties.VariableNames,b.Properties.VariableNames)&&height(a)==height(b), ...
    'payload:Schema','Evaluation table columns or row counts differ.');
a=sortrows(a,keys);b=sortrows(b,keys);columns=struct([]);passed=true;
for name=a.Properties.VariableNames
    field=name{1};x=a.(field);y=b.(field);tolerance=0;delta=0;
    if isnumeric(x)&&isnumeric(y)
        if ismember(field,{'mass_kg','cx_m','cz_m'}),tolerance=1e-7;
        elseif startsWith(field,'true_'),tolerance=1e-12;
        elseif contains(field,{'mae','rmse','p95','max','distance','error','delta','ci95','upper'}),tolerance=1e-4;
        end
        finite=isfinite(x)&isfinite(y);
        pattern=isequal(isfinite(x),isfinite(y))&&isequal(isnan(x),isnan(y))&&isequal(x(isinf(x)),y(isinf(y)));
        difference=abs(x(finite)-y(finite));if ~isempty(difference),delta=max(difference);end
        same=pattern&&all(difference<=tolerance);
    else,same=isequaln(string(x),string(y));end
    row=struct('name',field,'absolute_tolerance',tolerance,'max_absolute_difference',delta,'passed',same);
    if isempty(columns),columns=row;else,columns(end+1)=row;end %#ok<AGROW>
    passed=passed&&same;
end
out=struct('rows',height(a),'passed',passed,'columns',columns);
end
