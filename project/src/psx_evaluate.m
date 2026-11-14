function info=psx_evaluate(D,bundle,options,outdir)
%PSX_EVALUATE Comparative evaluation across simulation conditions.
% No result-dependent winner or inherited eight-/24-endpoint rule is used.
% Smoke output checks execution only and deliberately has no confidence CI.
o=validate_inputs(D,bundle,options);outdir=char(outdir);
if ~isfolder(outdir),mkdir(outdir);end
identity=struct('schema','psx_evaluation_identity_v1','dataset_hash',pnn_model_hash(D), ...
    'bundle_hash',pnn_model_hash(bundle),'options',o,'source_hashes',source_hashes(), ...
    'matlab_release',version('-release'));
identity_hash=pnn_model_hash(identity);donefile=fullfile(outdir,'EVALUATION_COMPLETE.json');
if isfile(donefile)
    info=jsondecode(fileread(donefile));
    assert(strcmp(info.identity_hash,identity_hash),'psx:EvalIdentity','Evaluation identity changed.');
    for k=1:numel(info.outputs)
        assert(isfile(info.outputs(k).path)&&strcmp(prc_file_hash(info.outputs(k).path),info.outputs(k).sha256), ...
            'psx:EvalIntegrity','Completed evaluation output changed: %s',info.outputs(k).path);
    end
    return
end
contract_file=fullfile(outdir,'EVALUATION_CONTRACT.mat');
if pnn_checkpoint('exists',contract_file)
    saved=pnn_checkpoint('read',contract_file);
    assert(isequaln(saved.identity,identity),'psx:EvalIdentity','Evaluation contract changed.');
else
    pnn_checkpoint('write',contract_file,struct('identity',identity));
end
n=size(D.theta,1);methods=string({bundle.methods.name});nm=numel(methods);
conditions=unique(string(D.condition(:)),'stable');
matrix_file=fullfile(outdir,'evaluation_matrices.mat');
if pnn_checkpoint('exists',matrix_file)
    saved=pnn_checkpoint('read',matrix_file);
    assert(strcmp(saved.identity_hash,identity_hash),'psx:EvalIdentity','Prediction checkpoint identity changed.');
    P=saved.raw_predictions;Q=saved.clipped_predictions;A=saved.accepted;C=saved.bounds_hit;
else
    P=nan(n,3,nm);A=false(n,nm);C=false(n,nm);details=cell(1,nm);
    for j=1:nm
        [p,detail]=pnn_predict(bundle,D,char(methods(j)));
        assert(isequal(size(p),[n 3]),'psx:PredictionSize','Wrong prediction shape.');
        finite=all(isfinite(p),2);
        P(:,:,j)=p;A(:,j)=logical(detail.accepted(:))&finite;
        C(:,j)=finite&any(p<o.bounds(:,1).'|p>o.bounds(:,2).',2);details{j}=detail;
    end
    Q=P;
    for j=1:nm
        finite=all(isfinite(P(:,:,j)),2);
        % A failed raw row remains failed, including any Inf component.
        Q(finite,:,j)=min(max(P(finite,:,j),o.bounds(:,1).'),o.bounds(:,2).');
    end
    saved=struct('identity_hash',identity_hash,'data',D,'method_names',methods, ...
        'raw_predictions',P,'clipped_predictions',Q,'accepted',A,'bounds_hit',C, ...
        'finite',reshape(all(isfinite(P),2),n,nm),'prediction_details',{details}, ...
        'smoke_only',o.smoke_test,'options',o);
    pnn_checkpoint('write',matrix_file,saved);
end
summary=struct([]);deltas=struct([]);prediction_tables=cell(nm*2,1);ti=0;
for post=1:2
    processing="raw";V=P;if post==2,processing="common_clip";V=Q;end
    for j=1:nm
        p=V(:,:,j);mass=abs(p(:,1)-D.theta(:,1))*1000;
        com=sqrt(sum((p(:,2:3)-D.theta(:,2:3)).^2,2))*1000;finite=all(isfinite(p),2);
        ti=ti+1;
        prediction_tables{ti}=table(D.trial_id(:),D.object_id(:),string(D.condition(:)), ...
            repmat(methods(j),n,1),repmat(processing,n,1),D.theta(:,1),D.theta(:,2),D.theta(:,3), ...
            p(:,1),p(:,2),p(:,3),finite,A(:,j),C(:,j),mass,com, ...
            'VariableNames',{'trial_id','object_id','condition','method','postprocessing', ...
            'true_mass_kg','true_cx_m','true_cz_m','mass_kg','cx_m','cz_m','finite','accepted', ...
            'bounds_hit','mass_abs_error_g','planar_com_distance_mm'});
        for c=1:numel(conditions)
            ix=string(D.condition(:))==conditions(c);valid=ix&finite;accepted=valid&A(:,j);
            row=struct('method',methods(j),'condition',conditions(c),'postprocessing',processing, ...
                'planned_n',sum(ix),'finite_n',sum(valid),'accepted_n',sum(accepted), ...
                'failed_n',sum(ix&~finite),'rejected_n',sum(ix&~A(:,j)), ...
                'finite_rejected_n',sum(valid&~A(:,j)),'clipped_n',sum(ix&C(:,j)), ...
                'finite_coverage',sum(valid)/sum(ix),'accepted_coverage',sum(accepted)/sum(ix), ...
                'mass_mae_g',average(mass(valid)),'mass_rmse_g',sqrt(average(mass(valid).^2)), ...
                'mass_p95_g',percent(mass(valid),95),'mass_max_g',maximum(mass(valid)), ...
                'planar_com_mean_distance_mm',average(com(valid)), ...
                'planar_com_p95_distance_mm',percent(com(valid),95),'planar_com_max_distance_mm',maximum(com(valid)), ...
                'accepted_mass_mae_g',average(mass(accepted)), ...
                'accepted_planar_com_mean_distance_mm',average(com(accepted)),'smoke_only',o.smoke_test);
            summary=append(summary,row);
        end
    end
    for pair_index=1:size(o.pairs,1)
        j=find(methods==string(o.pairs{pair_index,1}));b=find(methods==string(o.pairs{pair_index,2}));
        for c=1:numel(conditions)
            ix=string(D.condition(:))==conditions(c);
            paired=ix&all(isfinite(V(:,:,j)),2)&all(isfinite(V(:,:,b)),2);
            ids=D.object_id(paired);[~,order]=sort(ids);
            first=errors(V(paired,:,j),D.theta(paired,:));second=errors(V(paired,:,b),D.theta(paired,:));
            difference=first(order,:)-second(order,:);
            if o.smoke_test,boot=[];effective_replicates=0;
            else,boot=paired_bootstrap(difference,o.bootstrap_replicates,o.bootstrap_seed);effective_replicates=o.bootstrap_replicates;end
            metrics=["mass_mae_g","planar_com_mean_distance_mm"];
            for metric=1:2
                lower=NaN;upper=NaN;
                if ~isempty(boot),lower=percent(boot(:,metric),2.5);upper=percent(boot(:,metric),97.5);end
                row=struct('method',methods(j),'baseline',methods(b),'condition',conditions(c), ...
                    'postprocessing',processing,'metric',metrics(metric),'planned_n',sum(ix), ...
                    'paired_n',sum(paired),'pair_coverage',sum(paired)/sum(ix), ...
                    'delta_mean',average(difference(:,metric)),'ci95_lower',lower,'ci95_upper',upper, ...
                    'accepted_n',sum(ix&A(:,j)),'baseline_accepted_n',sum(ix&A(:,b)), ...
                    'all_planned_pairs_finite',sum(paired)==sum(ix), ...
                    'bootstrap_replicates',effective_replicates,'smoke_only',o.smoke_test);
                deltas=append(deltas,row);
            end
        end
    end
end
write_table_new(struct2table(summary),fullfile(outdir,'summary.csv'));
write_table_new(struct2table(deltas),fullfile(outdir,'paired_intervals.csv'));
write_table_new(vertcat(prediction_tables{:}),fullfile(outdir,'predictions.csv'));
names={'EVALUATION_CONTRACT.mat','EVALUATION_CONTRACT.mat.sha256.json', ...
    'evaluation_matrices.mat','evaluation_matrices.mat.sha256.json','summary.csv','paired_intervals.csv','predictions.csv'};
outputs=repmat(struct('path','','sha256',''),numel(names),1);
for k=1:numel(names),outputs(k).path=fullfile(outdir,names{k});outputs(k).sha256=prc_file_hash(outputs(k).path);end
info=struct('schema','psx_evaluation_complete_v1','completed_utc',pnn_utc(),'identity_hash',identity_hash, ...
    'dataset_hash',identity.dataset_hash,'bundle_hash',identity.bundle_hash,'smoke_only',o.smoke_test, ...
    'planned_trials',n,'unique_objects',numel(unique(D.object_id)),'methods',nm, ...
    'conditions',numel(conditions),'comparison_pairs',size(o.pairs,1),'outputs',outputs, ...
    'inference','Descriptive paired object bootstrap only; no multiplicity-adjusted superiority decision.', ...
    'scope','Every planned row retained; raw all-finite errors primary, accepted errors separate; clipping never repairs a failed row.');
if o.smoke_test,info.inference='SMOKE ONLY: no confidence intervals or scientific performance conclusion.';end
write_json_new(donefile,info);
end

function o=validate_inputs(D,bundle,o)
required={'theta','base','X13','Xaug','usable','accepted','object_id','trial_id','condition'};
assert(isstruct(D)&&isscalar(D)&&all(isfield(D,required)),'psx:EvalData','Dataset fields missing.');
n=size(D.theta,1);assert(n>=1&&size(D.theta,2)==3&&all(isfinite(D.theta),'all'),'psx:EvalData','Finite true parameters required.');
for k=1:numel(required),assert(size(D.(required{k}),1)==n,'psx:EvalData','Dataset row count mismatch.');end
assert(numel(unique(D.trial_id))==n&&all(isfinite(D.trial_id))&&all(isfinite(D.object_id)), ...
    'psx:EvalData','Finite unique trial identities required.');
conditions=string(D.condition(:));assert(~any(ismissing(conditions)|strlength(conditions)==0),'psx:EvalData','Empty condition.');
for c=reshape(unique(conditions),1,[])
    ids=D.object_id(conditions==c);assert(numel(unique(ids))==numel(ids),'psx:RepeatedObject','One trial per object per condition required.');
end
if isfield(D,'split'),assert(all(string(D.split)=="test"),'psx:EvalSplit','Only locked test or smoke-test rows allowed.');end
assert(isstruct(bundle)&&isfield(bundle,'methods')&&~isempty(bundle.methods),'psx:EvalBundle','Missing model methods.');
names=string({bundle.methods.name});assert(numel(unique(names))==numel(names),'psx:EvalBundle','Duplicate method names.');
fields={'smoke_test','bootstrap_replicates','bootstrap_seed','bounds','pairs'};
assert(isstruct(o)&&isscalar(o)&&all(isfield(o,fields)),'psx:EvalOptions','Explicit evaluation settings required.');
assert(islogical(o.smoke_test)&&isscalar(o.smoke_test),'psx:EvalOptions','smoke_test must be explicit logical.');
assert(isequal(size(o.bounds),[3 2])&&all(isfinite(o.bounds),'all')&&all(o.bounds(:,1)<o.bounds(:,2)), ...
    'psx:EvalOptions','Invalid common bounds.');
assert(isscalar(o.bootstrap_replicates)&&isfinite(o.bootstrap_replicates)&&o.bootstrap_replicates>=double(~o.smoke_test)&& ...
    o.bootstrap_replicates==floor(o.bootstrap_replicates)&&isscalar(o.bootstrap_seed)&& ...
    isfinite(o.bootstrap_seed)&&o.bootstrap_seed>=0&&o.bootstrap_seed<=2^32-1&&o.bootstrap_seed==floor(o.bootstrap_seed), ...
    'psx:EvalOptions','Invalid bootstrap settings.');
assert(iscell(o.pairs)&&size(o.pairs,2)==2&&size(o.pairs,1)>=1,'psx:EvalOptions','Explicit nonempty N-by-2 method/baseline pairs required.');
pairs=string(o.pairs);assert(all(ismember(pairs,names),'all')&&all(pairs(:,1)~=pairs(:,2))&& ...
    size(unique(pairs,'rows'),1)==size(pairs,1),'psx:EvalOptions','Unknown, self, or duplicate comparison.');
o.pairs=cellstr(pairs);
end
function hashes=source_hashes()
names={'psx_evaluate','pnn_predict','pnn_nn_predict','pnn_ridge_predict','pnn_checkpoint', ...
    'pnn_model_hash','prc_file_hash'};hashes=struct('name',{},'sha256',{});
for k=1:numel(names),hashes(k)=struct('name',names{k},'sha256',prc_file_hash(which(names{k})));end
end
function e=errors(p,t),e=[abs(p(:,1)-t(:,1))*1000 sqrt(sum((p(:,2:3)-t(:,2:3)).^2,2))*1000];end
function B=paired_bootstrap(difference,reps,seed)
n=size(difference,1);B=nan(reps,2);if n==0,return;end
stream=RandStream('mt19937ar','Seed',seed);
for first=1:100:reps
    ids=first:min(first+99,reps);ix=randi(stream,n,n,numel(ids));
    for metric=1:2,v=difference(:,metric);B(ids,metric)=mean(reshape(v(ix),n,numel(ids)),1).';end
end
end
function rows=append(rows,row),if isempty(rows),rows=row;else,rows(end+1)=row;end,end
function v=average(x),v=NaN;if ~isempty(x),v=mean(x);end,end
function v=maximum(x),v=NaN;if ~isempty(x),v=max(x);end,end
function v=percent(x,p),v=NaN;if ~isempty(x)&&all(isfinite(x)),v=prctile(x,p);end,end
function write_table_new(T,file)
temporary=[file '.' char(java.util.UUID.randomUUID()) '.tmp'];
writetable(T,temporary,'FileType','text');
if isfile(file)
    assert(strcmp(prc_file_hash(file),prc_file_hash(temporary)),'psx:EvalIntegrity','Existing table differs; refusing to replace %s.',file);
    delete(temporary);
else
    [ok,msg]=movefile(temporary,file);assert(ok,'psx:EvalWrite','%s',msg);
end
end
function write_json_new(file,value)
assert(~isfile(file),'psx:EvalExists','Refusing to replace existing completion.');
temporary=[file '.' char(java.util.UUID.randomUUID()) '.tmp'];fid=fopen(temporary,'w','n','UTF-8');
assert(fid>=0,'psx:EvalWrite','Cannot create completion.');cleanup=onCleanup(@()fclose(fid));
fprintf(fid,'%s\n',jsonencode(value,PrettyPrint=true));clear cleanup
assert(~isfile(file),'psx:EvalExists','Completion appeared during write.');
[ok,msg]=movefile(temporary,file);assert(ok,'psx:EvalWrite','%s',msg);
end
