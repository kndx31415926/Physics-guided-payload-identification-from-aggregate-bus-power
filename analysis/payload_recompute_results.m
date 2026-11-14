function report = payload_recompute_results(packageRoot, outputDirectory)
%PAYLOAD_RECOMPUTE_RESULTS Compute descriptive errors and coverage from CSVs.
%   Reads study predictions and writes summaries to a new output directory.
%   Retains all estimators and both postprocessing variants. Bootstrap
%   intervals are computed by the evaluation and online-statistics functions.

packageRoot = canonical(packageRoot);
outputDirectory = canonical(outputDirectory);
assert(isfolder(packageRoot), 'payload:Package', 'Package directory is missing.');
for protected = ["studies", "data", "analysis"]
    p = canonical(fullfile(packageRoot, protected));
    assert(~sameOrBelow(outputDirectory, p), 'payload:Output', ...
        'Choose an output folder outside studies, data, and analysis.');
end
if isfolder(outputDirectory)
    entries = dir(outputDirectory);
    assert(all(ismember({entries.name}, {'.','..'})), 'payload:Output', ...
        'Output directory must be new or empty; existing files are never replaced.');
else
    assert(~isfile(outputDirectory), 'payload:Output', 'Output path is a file.');
    mkdir(outputDirectory);
end

jobs = registry();
comparisons = struct([]);
panels = struct([]);
for j = 1:numel(jobs)
    job = jobs(j);
    studyRoot = fullfile(packageRoot, 'studies', job.study);
    predPath = fullfile(studyRoot, job.predictions);
    summaryPath = fullfile(studyRoot, job.summary);
    if ~isfolder(studyRoot) && ~job.required
        continue
    end
    assert(isfile(predPath) && isfile(summaryPath), 'payload:Input', ...
        'Missing input for %s / %s.', job.study, job.panel);
    R = readtable(predPath, 'TextType', 'string', 'VariableNamingRule', 'preserve');
    S = readtable(summaryPath, 'TextType', 'string', 'VariableNamingRule', 'preserve');
    if job.terminal
        assert(ismember('block', R.Properties.VariableNames), 'payload:Schema', 'Missing block.');
        % The archived protocol has four blocks; this is not selected by error.
        assert(all(ismember(unique(R.block), 1:4)), 'payload:Blocks', 'Unexpected block index.');
        R = R(R.block == 4, :);
    end
    [B, rows] = recompute(R, S, job);
    resultPath = fullfile(outputDirectory, [job.panel '_recomputed.csv']);
    writetable(B, resultPath);
    if isempty(comparisons), comparisons = rows; else, comparisons = [comparisons; rows]; end %#ok<AGROW>
    panel = struct('study',job.study,'panel',job.panel, ...
        'predictions',strrep(fullfile('studies',job.study,job.predictions),'\','/'), ...
        'summary',strrep(fullfile('studies',job.study,job.summary),'\','/'), ...
        'prediction_rows',height(R),'summary_rows',height(S), ...
        'methods',numel(unique(string(R.method))), ...
        'postprocessing',{cellstr(unique(string(R.postprocessing)))}, ...
        'comparisons',numel(rows),'failed_comparisons',sum(~[rows.passed]), ...
        'max_absolute_difference',max([rows.absolute_difference],[],'omitnan'));
    if isempty(panels), panels = panel; else, panels(end+1,1) = panel; end %#ok<AGROW>
end
assert(~isempty(comparisons), 'payload:Empty', 'No study tables were processed.');
C = struct2table(comparisons);
writetable(C, fullfile(outputDirectory, 'summary_comparisons.csv'));
report = struct('schema','payload_descriptive_recomputation_v1', ...
    'created_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')), ...
    'matlab_version',version,'panels',panels, ...
    'comparison_count',height(C),'failed_comparisons',sum(~C.passed), ...
    'all_passed',all(C.passed), ...
    'scope','Point estimates and coverage from individual predictions for all estimators and both postprocessing variants.', ...
    'units','Mass absolute error in g; Euclidean planar center-of-mass error in mm.', ...
    'interval_scope','Bootstrap intervals use objects or complete streams in the separate evaluation functions.', ...
    'tolerance','Counts exact; rates 1e-12; errors 1e-8 + 1e-10*abs(source) in reported units, allowing decimal CSV rounding.');
writeJson(fullfile(outputDirectory, 'recomputation_report.json'), report);
fprintf('Recomputed %d panels and compared %d summary values: %d differences beyond tolerance.\n', ...
    numel(panels), height(C), sum(~C.passed));
assert(report.all_passed, 'payload:Difference', ...
    'Summary differences were found; inspect summary_comparisons.csv in the output folder.');
end

function jobs = registry()
jobs = struct('study',{},'panel',{},'predictions',{},'summary',{}, ...
    'kind',{},'keys',{},'units',{},'terminal',{},'required',{});
keys = {'method','condition','postprocessing'};
jobs(end+1) = item('pnn_large_training_20261031_v1','pnn','predictions.csv','summary.csv','offline',keys,{'trial_id'},false,true);
jobs(end+1) = item('psx_supplement_formal_20261106_v1','psx_original', ...
    'original_evaluation/predictions.csv','original_evaluation/summary.csv','offline',keys,{'trial_id'},false,false);
jobs(end+1) = item('pbd_exploration_20261110_v1','pbd', ...
    'snapshots/snapshot_012/evaluation/predictions.csv','snapshots/snapshot_012/evaluation/summary.csv', ...
    'offline',keys,{'trial_id'},false,false);
jobs(end+1) = item('pca_convex_audit_20261111_v1','pca_original', ...
    'original_evaluation/predictions.csv','original_evaluation/summary.csv','offline',keys,{'trial_id'},false,true);
jobs(end+1) = item('pca_convex_audit_20261111_v1','pca_cross', ...
    'pbd_evaluation/predictions.csv','pbd_evaluation/summary.csv','offline',keys,{'trial_id'},false,true);
studies = {'pcu_prospective_20261030_v1','pcr_online_ridge_20261031_v4'};
prefixes = {'pcu','pcr'};
for i = 1:2
    study = studies{i}; prefix = prefixes{i};
    keys = {'scenario','method','postprocessing'};
    units = {'stream_seed','trial_id'};
    jobs(end+1) = item(study,[prefix '_pooled'],'online_predictions.csv','online_pooled_summary.csv','online',keys,units,false,true); %#ok<AGROW>
    jobs(end+1) = item(study,[prefix '_stream'],'online_predictions.csv','online_stream_summary.csv','online', ...
        {'scenario','stream_seed','method','postprocessing'},units,false,true); %#ok<AGROW>
    jobs(end+1) = item(study,[prefix '_block'],'online_predictions.csv','online_block_summary.csv','online', ...
        {'scenario','stream_seed','block','method','postprocessing'},units,false,true); %#ok<AGROW>
    jobs(end+1) = item(study,[prefix '_retention'],'retention_predictions.csv','retention_summary.csv','online', ...
        {'scenario','stream_seed','method','postprocessing'},units,false,true); %#ok<AGROW>
    jobs(end+1) = item(study,[prefix '_terminal'],'online_predictions.csv','terminal_block_summary.csv','online',keys,units,true,true); %#ok<AGROW>
end
jobs(end+1) = item('psv_frozen_confirmation_20261030_v2','psv', ...
    'predictions.csv','summary.csv','psv', ...
    {'condition','jitter_seed','train_budget','method','model_seed','model_kind','postprocessing'}, ...
    {'case_id'},false,true);
end

function job = item(study,panel,predictions,summary,kind,keys,units,terminal,required)
job = struct('study',study,'panel',panel,'predictions',predictions,'summary',summary, ...
    'kind',kind,'keys',{keys},'units',{units},'terminal',terminal,'required',required);
end

function [B, rows] = recompute(R, S, job)
assert(height(R)>0 && height(S)>0, 'payload:Empty', 'Empty input table.');
assert(all(ismember(job.keys,R.Properties.VariableNames)) && ...
    all(ismember(job.keys,S.Properties.VariableNames)), 'payload:Schema', 'Missing group keys.');
identity = keyString(R, unique([job.keys job.units], 'stable'));
assert(numel(unique(identity)) == height(R), 'payload:Identity', ...
    'Duplicate prediction identity in %s.', job.panel);
rk = keyString(R,job.keys); sk = keyString(S,job.keys);
assert(numel(unique(sk)) == height(S), 'payload:Identity', 'Duplicate summary key.');
[g, groupKeys] = findgroups(rk);
[present,index] = ismember(sk,groupKeys);
assert(all(present) && numel(unique(index)) == numel(groupKeys), 'payload:Coverage', ...
    'Summary groups and prediction groups differ in %s.', job.panel);
if strcmp(job.kind,'online')
    truth = R{:,{'mass_true_kg','cx_true_m','cz_true_m'}};
    prediction = R{:,{'mass_est_kg','cx_est_m','cz_est_m'}};
    finiteFlag = flag(R,'finite_prediction');
elseif strcmp(job.kind,'psv')
    truth = R{:,{'true_mass_kg','true_cx_m','true_cz_m'}};
    prediction = R{:,{'pred_mass_kg','pred_cx_m','pred_cz_m'}};
    finiteFlag = flag(R,'finite_prediction');
else
    truth = R{:,{'true_mass_kg','true_cx_m','true_cz_m'}};
    prediction = R{:,{'mass_kg','cx_m','cz_m'}};
    finiteFlag = flag(R,'finite');
end
assert(all(isfinite(truth),'all'), 'payload:Truth', 'Nonfinite true parameters.');
coordinateFinite = all(isfinite(prediction),2);
assert(~any(finiteFlag & ~coordinateFinite), 'payload:Finite', 'Finite flag contradicts coordinates.');
finite = finiteFlag & coordinateFinite;
accepted = flag(R,'accepted');
assert(~any(accepted & ~finite), 'payload:Accepted', 'Accepted row is not finite.');
errors = 1000*(prediction-truth);
mass = abs(errors(:,1)); com = sqrt(sum(errors(:,2:3).^2,2));
B = S(:,job.keys);
rows = struct([]);
for i = 1:height(S)
    use = g == index(i); f = use & finite; a = use & accepted;
    v = struct(); n = sum(use); nf = sum(f); na = sum(a);
    v.planned_n=n; v.planned_cases=n; v.total_n=n;
    v.finite_n=nf; v.accepted_n=na; v.failed_n=n-nf; v.missing_n=n-nf;
    v.rejected_n=n-na; v.finite_rejected_n=nf-na;
    v.finite_coverage=nf/n; v.prediction_coverage=nf/n;
    v.accepted_coverage=na/n; v.coverage=na/n;
    v.mass_mae_g=average(mass(f)); v.mass_rmse_g=sqrt(average(mass(f).^2));
    v.mass_max_g=maximum(mass(f));
    v.planar_com_mean_distance_mm=average(com(f)); v.com_mae_mm=v.planar_com_mean_distance_mm;
    v.planar_com_max_distance_mm=maximum(com(f)); v.com_max_mm=v.planar_com_max_distance_mm;
    v.com_rmse_mm=sqrt(average(com(f).^2));
    v.accepted_mass_mae_g=average(mass(a)); v.mass_accepted_mae_g=v.accepted_mass_mae_g;
    v.accepted_planar_com_mean_distance_mm=average(com(a)); v.com_accepted_mae_mm=v.accepted_planar_com_mean_distance_mm;
    for axis = 2:3
        name = 'cx'; if axis==3, name='cz'; end
        e = abs(errors(:,axis));
        v.([name '_mae_mm'])=average(e(f));
        v.([name '_rmse_mm'])=sqrt(average(e(f).^2));
        v.([name '_max_mm'])=maximum(e(f));
        v.(['accepted_' name '_mae_mm'])=average(e(a));
        v.([name '_accepted_mae_mm'])=average(e(a));
    end
    if ismember('bounds_hit', R.Properties.VariableNames)
        b=flag(R,'bounds_hit'); v.clipped_n=sum(use & b); v.bound_hit_n=v.clipped_n; v.bounds_hit_rate=v.clipped_n/n;
    end
    optional = {'physical_success','physical_failure_n';'steady_usable','steady_unusable_n';'physics_usable','physics_unusable_n'};
    for k=1:size(optional,1)
        if ismember(optional{k,1},R.Properties.VariableNames)
            b=flag(R,optional{k,1}); v.(optional{k,2})=sum(use & ~b);
        end
    end
    names=intersect(S.Properties.VariableNames,fieldnames(v),'stable');
    for k=1:numel(names)
        name=names{k}; expected=double(S.(name)(i)); actual=v.(name);
        if ~ismember(name,B.Properties.VariableNames), B.(name)=nan(height(S),1); end
        B.(name)(i,1)=actual;
        if endsWith(name,'_n') || ismember(name,{'planned_cases'})
            tolerance=0;
        elseif contains(name,'coverage') || strcmp(name,'bounds_hit_rate')
            tolerance=1e-12;
        else
            tolerance=1e-8+1e-10*abs(expected);
        end
        difference=abs(actual-expected);
        passed=(isnan(actual)&&isnan(expected)) || (isfinite(actual)&&isfinite(expected)&&difference<=tolerance);
        row=struct('study',string(job.study),'panel',string(job.panel),'group',sk(i), ...
            'metric',string(name),'source_value',expected,'recomputed_value',actual, ...
            'absolute_difference',difference,'tolerance',tolerance,'passed',passed);
        if isempty(rows), rows=row; else, rows(end+1,1)=row; end %#ok<AGROW>
    end
end
end

function k = keyString(T,names)
assert(all(ismember(names,T.Properties.VariableNames)), 'payload:Schema', 'Missing identity column.');
k=repmat("",height(T),1);
for i=1:numel(names)
    x=string(T.(names{i}));
    assert(~any(ismissing(x)|contains(x,'|')), 'payload:Identity', 'Missing or invalid identity value.');
    k=k+"|"+string(names{i})+"="+x;
end
end

function x = flag(T,name)
x=T.(name);
if isstring(x)||iscellstr(x)||iscategorical(x)
    x=lower(string(x));
    assert(all(ismember(x,["0","1","false","true"])), 'payload:Flag', 'Invalid flag %s.',name);
    x=ismember(x,["1","true"]);
else
    assert(all(isfinite(x)&ismember(x,[0 1])), 'payload:Flag', 'Invalid flag %s.',name);
    x=logical(x);
end
end
function y=average(x), y=NaN; if ~isempty(x), y=mean(x); end, end
function y=maximum(x), y=NaN; if ~isempty(x), y=max(x); end, end
function p=canonical(p), p=char(java.io.File(char(p)).getCanonicalPath()); end
function yes=sameOrBelow(p,base)
if ispc, p=lower(p); base=lower(base); end
yes=strcmp(p,base)||startsWith(p,[base filesep]);
end
function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8'); assert(fid>=0,'payload:Write','Cannot create report.');
cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
