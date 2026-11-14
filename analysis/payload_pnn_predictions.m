function report=payload_pnn_predictions(packageRoot,outputDir)
% Apply nine saved estimators to the compact features of 8000 test trials.
% Usage: addpath('<package>/analysis'); payload_pnn_predictions('<package>');
% Retains every planned row with raw and common-clipped predictions.
if nargin<1||isempty(packageRoot),packageRoot=fileparts(fileparts(mfilename('fullpath')));end
if nargin<2,outputDir='';end
[S,paths,restorePath]=payload_pnn_setup(packageRoot); %#ok<ASGLU>
outputDir=payload_pnn_output_dir(paths.root,outputDir,'pnn_predictions');
D=S.test;bundle=S.bundle;spec=S.spec;n=size(D.theta,1);methods=string({bundle.methods.name});nm=numel(methods);
assert(n==8000&&nm==9&&numel(unique(D.object_id))==2000,'payload:Counts','Expected 8000 trials, 2000 objects and nine methods.');
conditions=unique(string(D.condition),'stable');assert(numel(conditions)==4,'payload:Conditions','Expected four test conditions.');
for c=reshape(conditions,1,[])
    ix=string(D.condition)==c;
    assert(sum(ix)==2000&&numel(unique(D.object_id(ix)))==2000,'payload:Pairing','Each condition must retain 2000 distinct objects.');
end
P=nan(n,3,nm);A=false(n,nm);C=false(n,nm);
for j=1:nm
    [p,detail]=pnn_predict(bundle,D,char(methods(j)));
    assert(isequal(size(p),[n 3]),'payload:Shape','Unexpected prediction dimensions.');
    P(:,:,j)=p;A(:,j)=logical(detail.accepted(:))&all(isfinite(p),2);
    C(:,j)=all(isfinite(p),2)&any(p<spec.bounds(:,1).'|p>spec.bounds(:,2).',2);
    fprintf('PNN inference %d/%d: %s, %d/%d finite.\n',j,nm,methods(j),sum(all(isfinite(p),2)),n);
end
predictionTables=cell(2*nm,1);summaryRows=struct([]);ti=0;
for post=1:2
    processing="raw";Q=P;
    if post==2
        processing="common_clip";
        for j=1:nm
            finiteRaw=all(isfinite(P(:,:,j)),2);
            Q(finiteRaw,:,j)=min(max(P(finiteRaw,:,j),spec.bounds(:,1).'),spec.bounds(:,2).');
        end
    end
    for j=1:nm
        q=Q(:,:,j);mass=abs(q(:,1)-D.theta(:,1))*1000;
        com=sqrt(sum((q(:,2:3)-D.theta(:,2:3)).^2,2))*1000;finite=all(isfinite(q),2);ti=ti+1;
        predictionTables{ti}=table(D.trial_id(:),D.object_id(:),string(D.condition(:)), ...
            repmat(methods(j),n,1),repmat(processing,n,1),D.theta(:,1),D.theta(:,2),D.theta(:,3), ...
            q(:,1),q(:,2),q(:,3),finite,A(:,j),C(:,j),mass,com, ...
            'VariableNames',{'trial_id','object_id','condition','method','postprocessing','true_mass_kg','true_cx_m','true_cz_m', ...
            'mass_kg','cx_m','cz_m','finite','accepted','bounds_hit','mass_abs_error_g','planar_com_distance_mm'});
        for c=reshape(conditions,1,[])
            ix=string(D.condition)==c;valid=ix&finite;accepted=valid&A(:,j);
            row=struct('method',methods(j),'condition',c,'postprocessing',processing, ...
                'planned_n',sum(ix),'finite_n',sum(valid),'accepted_n',sum(accepted),'failed_n',sum(ix&~finite), ...
                'clipped_n',sum(ix&C(:,j)),'finite_coverage',sum(valid)/sum(ix),'accepted_coverage',sum(accepted)/sum(ix), ...
                'mass_mae_g',average(mass(valid)),'mass_rmse_g',sqrt(average(mass(valid).^2)), ...
                'mass_p95_g',percentile(mass(valid),95),'mass_max_g',maximum(mass(valid)), ...
                'planar_com_mean_distance_mm',average(com(valid)),'planar_com_p95_distance_mm',percentile(com(valid),95), ...
                'planar_com_max_distance_mm',maximum(com(valid)), ...
                'accepted_mass_mae_g',average(mass(accepted)),'accepted_planar_com_mean_distance_mm',average(com(accepted)));
            if isempty(summaryRows),summaryRows=row;else,summaryRows(end+1)=row;end %#ok<AGROW>
        end
    end
end
predictions=vertcat(predictionTables{:});summary=struct2table(summaryRows);
assert(height(predictions)==144000&&height(summary)==72,'payload:Counts','Missing method, processing or condition rows.');
reference=payload_pnn_read_csv(fullfile(paths.study,'predictions.csv'),'predictions');
referenceSummary=payload_pnn_read_csv(fullfile(paths.study,'summary.csv'),'summary');
predictionComparison=compare_predictions(predictions,reference);
summaryComparison=compare_summary(summary,referenceSummary);
writetable(predictions,fullfile(outputDir,'recomputed_predictions.csv'));
writetable(summary,fullfile(outputDir,'recomputed_summary.csv'));
save(fullfile(outputDir,'recomputed_predictions.mat'),'P','A','C','methods','conditions','-v7.3');
report=struct('schema','payload_pnn_predictions_v1','completed_utc',char(datetime('now','TimeZone','UTC', ...
    'Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z''')),'release',version('-release'), ...
    'source_model_sha256',S.lock.bundle_sha256,'export_sha256',S.export_manifest.export_sha256, ...
    'source_matlab_files_verified',S.source_matlab_files_verified,'value_hashes',S.value_hashes, ...
    'planned_trials',n,'independent_test_objects',numel(unique(D.object_id)),'methods',nm, ...
    'prediction_rows',height(predictions),'summary_rows',height(summary),'models_trained',0,'raw_trajectories_loaded',0, ...
    'new_simulations',0,'prediction_comparison',predictionComparison,'summary_comparison',summaryComparison, ...
    'passed',predictionComparison.passed&&summaryComparison.passed, ...
    'scope','Saved-model predictions for all planned test objects, with raw and common-clipped outputs.');
payload_pnn_write_json(fullfile(outputDir,'PNN_PAYLOAD_COMPLETE.json'),report);
assert(report.passed,'payload:PredictionMismatch','Numerical results differ. See comparison details in %s.',outputDir);
fprintf('PNN_PAYLOAD_COMPLETE: %d prediction rows agree with the reference within the specified tolerances.\n%s\n',height(predictions),outputDir);
end
function out=compare_predictions(actual,reference)
keys={'method','postprocessing','trial_id'};actual=sortrows(actual,keys);reference=sortrows(reference,keys);
assert(height(actual)==height(reference),'payload:ReferenceRows','Reference row count differs.');
for name={'method','postprocessing','condition'}
    assert(isequal(string(actual.(name{1})),string(reference.(name{1}))),'payload:ReferenceIdentity','Reference %s differs.',name{1});
end
for name={'trial_id','object_id','finite','accepted','bounds_hit'}
    assert(isequal(numeric(actual.(name{1})),numeric(reference.(name{1}))),'payload:ReferenceIdentity','Reference %s differs.',name{1});
end
fields={'true_mass_kg','true_cx_m','true_cz_m','mass_kg','cx_m','cz_m','mass_abs_error_g','planar_com_distance_mm'};
tolerances=[1e-12 1e-12 1e-12 1e-7 1e-7 1e-7 1e-4 1e-4];
out=compare_numeric(actual,reference,fields,tolerances);out.identity_columns_exact=true;
end
function out=compare_summary(actual,reference)
keys={'method','condition','postprocessing'};actual=sortrows(actual,keys);reference=sortrows(reference,keys);
assert(height(actual)==height(reference),'payload:ReferenceRows','Reference summary row count differs.');
for name=keys
    assert(isequal(string(actual.(name{1})),string(reference.(name{1}))),'payload:ReferenceIdentity','Reference %s differs.',name{1});
end
counts={'planned_n','finite_n','accepted_n','failed_n','clipped_n','finite_coverage','accepted_coverage'};
for name=counts
    assert(isequaln(actual.(name{1}),reference.(name{1})),'payload:Coverage','Reference coverage %s differs.',name{1});
end
fields={'mass_mae_g','mass_rmse_g','mass_p95_g','mass_max_g','planar_com_mean_distance_mm', ...
    'planar_com_p95_distance_mm','planar_com_max_distance_mm','accepted_mass_mae_g','accepted_planar_com_mean_distance_mm'};
out=compare_numeric(actual,reference,fields,repmat(1e-4,1,numel(fields)));out.coverage_columns_exact=true;
end
function out=compare_numeric(actual,reference,fields,tolerances)
out=struct('passed',true,'columns',struct([]));
for k=1:numel(fields)
    a=actual.(fields{k});b=reference.(fields{k});finite=isfinite(a)&isfinite(b);
    pattern=isequal(isfinite(a),isfinite(b))&&isequal(isnan(a),isnan(b))&&isequal(a(isinf(a)),b(isinf(b)));
    difference=abs(a(finite)-b(finite));if isempty(difference),delta=0;else,delta=max(difference);end
    row=struct('name',fields{k},'absolute_tolerance',tolerances(k),'max_absolute_difference',delta, ...
        'nonfinite_pattern_matches',pattern,'passed',pattern&&all(difference<=tolerances(k)));
    if isempty(out.columns),out.columns=row;else,out.columns(end+1)=row;end
    out.passed=out.passed&&row.passed;
end
end
function v=numeric(v)
if islogical(v)||isnumeric(v),v=double(v);return,end
text=string(v);if all(ismember(lower(text),["true","false"])),v=double(lower(text)=="true");else,v=str2double(text);end
end
function v=average(x),v=NaN;if ~isempty(x),v=mean(x);end,end
function v=maximum(x),v=NaN;if ~isempty(x),v=max(x);end,end
function v=percentile(x,p),v=NaN;if ~isempty(x)&&all(isfinite(x)),v=prctile(x,p);end,end
