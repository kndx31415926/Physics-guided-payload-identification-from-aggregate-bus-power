function info=pcr_compare_models(run_dir,spec)
% Locked supplemental comparison: NN minus ridge, whole-stream bootstrap.
R=read_predictions(fullfile(run_dir,'online_predictions.csv'));
N=read_predictions(fullfile(spec.data_source_dir,'online_predictions.csv'));
methods=["frozen","empty_only","gated_calibration","gated_full"];
N=N(ismember(N.method,methods),:);
assert(height(R)==4096&&height(N)==4096,'pcr:Count','Expected512 events x4methods x2postprocessings.');
keys={'scenario','stream_seed','block','method','postprocessing','trial_id','object_id'};
R=sortrows(R,keys);N=sortrows(N,keys);
assert(isequal(R(:,keys),N(:,keys)),'pcr:Pairing','Unmatched original NN/ridge records.');
truth={'mass_true_kg','cx_true_m','cz_true_m'};
assert(isequal(R{:,truth},N{:,truth})&&all(R.evaluated_before_current_update)&&all(N.evaluated_before_current_update), ...
    'pcr:Chronology','Unmatched truth or evaluation chronology.');
summaries=struct([]);deltas=struct([]);intervals=struct([]);
rs=rng;cl=onCleanup(@()rng(rs));rng(spec.bootstrap_seed,'twister'); %#ok<NASGU>
for period=["all_blocks","last_unknown_block"]
    if period=="all_blocks",keep=true(height(R),1);else,keep=R.block==spec.blocks;end
    RR=R(keep,:);NN=N(keep,:);
    [g,G]=findgroups(RR(:,{'scenario','method','postprocessing'}));
    for i=1:height(G)
        r=RR(g==i,:);n=NN(g==i,:);
        for algorithm=["NN","ridge"]
            if algorithm=="NN",q=n;else,q=r;end
            e=errors(q);valid=all(isfinite(e),2)&q.finite_prediction;
            row=struct('scenario',G.scenario(i),'method',G.method(i),'postprocessing',G.postprocessing(i), ...
                'period',period,'algorithm',algorithm,'total_n',height(q),'finite_n',sum(valid), ...
                'accepted_n',sum(valid&q.accepted),'physical_failure_n',sum(~q.physical_success), ...
                'bound_hit_n',sum(q.bounds_hit),'mass_mae_g',mean(e(valid,1)), ...
                'cx_mae_mm',mean(e(valid,2)),'cz_mae_mm',mean(e(valid,3)),'com_mae_mm',mean(e(valid,4)));
            summaries=append(summaries,row);
        end
        seeds=unique(r.stream_seed);assert(numel(seeds)==8,'pcr:Streams','Expected eight independent streams.');
        ds=nan(8,4);paired_n=zeros(8,1);
        for j=1:8
            x=r(r.stream_seed==seeds(j),:);y=n(n.stream_seed==seeds(j),:);
            er=errors(x);en=errors(y);valid=all(isfinite([er en]),2)&x.finite_prediction&y.finite_prediction;
            paired_n(j)=sum(valid);ds(j,:)=mean(en(valid,:)-er(valid,:),1);
            row=struct('scenario',G.scenario(i),'method',G.method(i),'postprocessing',G.postprocessing(i),'period',period, ...
                'stream_seed',seeds(j),'total_n',height(x),'paired_finite_n',paired_n(j),'acceptance_disagreement_n',sum(xor(x.accepted,y.accepted)), ...
                'mass_nn_minus_ridge_g',ds(j,1),'cx_nn_minus_ridge_mm',ds(j,2),'cz_nn_minus_ridge_mm',ds(j,3),'com_nn_minus_ridge_mm',ds(j,4));
            deltas=append(deltas,row);
        end
        index=randi(8,8,spec.bootstrap_repeats);names=["mass_g","cx_mm","cz_mm","com_mm"];
        for j=1:4
            v=ds(:,j);limits=[NaN NaN];
            if all(isfinite(v)),limits=prctile(mean(v(index),1),[2.5 97.5]);end
            row=struct('scenario',G.scenario(i),'method',G.method(i),'postprocessing',G.postprocessing(i),'period',period, ...
                'metric',names(j),'stream_n',8,'paired_finite_n',sum(paired_n),'mean_nn_minus_ridge',mean(v), ...
                'ci95_lower',limits(1),'ci95_upper',limits(2),'bootstrap_repeats',spec.bootstrap_repeats,'positive_favors',"ridge");
            intervals=append(intervals,row);
        end
    end
end
writetable(struct2table(summaries),fullfile(run_dir,'matched_model_summary.csv'));
writetable(struct2table(deltas),fullfile(run_dir,'matched_model_stream_deltas.csv'));
writetable(struct2table(intervals),fullfile(run_dir,'matched_model_paired_intervals.csv'));
info=struct('schema','pcr_cross_model_matched_v1','prediction_rows_per_model',height(R),'unknown_events',512, ...
    'bootstrap_unit','entire independent object/noise stream; eight per fixed law', ...
    'difference_direction','NN minus ridge; positive favors ridge','resamples',spec.bootstrap_repeats, ...
    'descriptive_intervals_no_multiplicity_correction',true);
prc_write_json(fullfile(run_dir,'MATCHED_ANALYSIS_COMPLETE.json'),info);
end
function R=read_predictions(path)
R=readtable(path,'TextType','string');
for f={'finite_prediction','accepted','physical_success','bounds_hit','evaluated_before_current_update'}
    x=R.(f{1});if isstring(x)||iscellstr(x),x=ismember(lower(string(x)),["true","1"]);end;R.(f{1})=logical(x);
end
end
function e=errors(Q)
e=1000*abs([Q.mass_est_kg-Q.mass_true_kg Q.cx_est_m-Q.cx_true_m Q.cz_est_m-Q.cz_true_m]);
e(:,4)=vecnorm(e(:,2:3),2,2);
end
function A=append(A,row),if isempty(A),A=row;else,A(end+1)=row;end,end
