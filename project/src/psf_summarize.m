function S=psf_summarize(R)
% Descriptive errors; every case remains in coverage denominators.
keys={'condition','jitter_seed','train_budget','method','model_seed','model_kind','postprocessing'};
[G,K]=findgroups(R(:,keys));rows=struct([]);
for k=1:height(K)
    Q=R(G==k,:);truth=[Q.true_mass_kg Q.true_cx_m Q.true_cz_m];p=[Q.pred_mass_kg Q.pred_cx_m Q.pred_cz_m];
    e=(p-truth)*1000;finite=Q.finite_prediction;accepted=Q.accepted;mae=nan(1,3);rmse=mae;ae=mae;p95=mae;maximum=mae;distance=NaN;d95=NaN;dmax=NaN;
    if any(finite)
        absolute=abs(e(finite,:));mae=mean(absolute,1);rmse=sqrt(mean(e(finite,:).^2,1));
        p95=prctile(absolute,95,1);maximum=max(absolute,[],1);
        d=vecnorm(e(finite,2:3),2,2);distance=mean(d);d95=prctile(d,95);dmax=max(d);
    end
    if any(accepted),ae=mean(abs(e(accepted,:)),1);end
    r=table2struct(K(k,:));r.aggregation="single_communication_replicate";r.replicate_count=1;r.planned_cases=height(Q);
    r.finite_n=sum(finite);r.accepted_n=sum(accepted);r.prediction_coverage=mean(finite);r.accepted_coverage=mean(accepted);r.bounds_hit_rate=mean(Q.bounds_hit);
    r.mass_mae_g=mae(1);r.cx_mae_mm=mae(2);r.cz_mae_mm=mae(3);r.planar_com_mean_distance_mm=distance;r.planar_com_p95_distance_mm=d95;
    r.mass_p95_g=p95(1);r.cx_p95_mm=p95(2);r.cz_p95_mm=p95(3);
    r.mass_max_g=maximum(1);r.cx_max_mm=maximum(2);r.cz_max_mm=maximum(3);r.planar_com_max_distance_mm=dmax;
    r.mass_rmse_g=rmse(1);r.cx_rmse_mm=rmse(2);r.cz_rmse_mm=rmse(3);
    r.accepted_mass_mae_g=ae(1);r.accepted_cx_mae_mm=ae(2);r.accepted_cz_mae_mm=ae(3);
    if isempty(rows),rows=r;else,rows(end+1)=r;end %#ok<AGROW>
end
S=struct2table(rows);keys={'condition','train_budget','method','model_seed','model_kind','postprocessing'};
[G,K]=findgroups(S(:,keys));aggregate=struct([]);
counts={'planned_cases','finite_n','accepted_n'};metrics={'prediction_coverage','accepted_coverage','bounds_hit_rate','mass_mae_g','cx_mae_mm','cz_mae_mm', ...
    'planar_com_mean_distance_mm','planar_com_p95_distance_mm','planar_com_max_distance_mm', ...
    'mass_p95_g','cx_p95_mm','cz_p95_mm','mass_max_g','cx_max_mm','cz_max_mm','mass_rmse_g','cx_rmse_mm','cz_rmse_mm', ...
    'accepted_mass_mae_g','accepted_cx_mae_mm','accepted_cz_mae_mm'};
for k=1:height(K)
    Q=S(G==k,:);if height(Q)==1,continue,end
    r=table2struct(Q(1,:));r.jitter_seed=-1;r.aggregation="mean_metrics_over_communication_replicates";r.replicate_count=height(Q);
    for j=1:numel(counts),r.(counts{j})=sum(Q.(counts{j}));end
    for j=1:numel(metrics),r.(metrics{j})=mean(Q.(metrics{j}));end
    if isempty(aggregate),aggregate=r;else,aggregate(end+1)=r;end %#ok<AGROW>
end
if ~isempty(aggregate),S=[S;struct2table(aggregate)];end
end
