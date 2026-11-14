function info=pra_summarize_online(run_dir,spec)
% Summaries retain rejection counts and use independent streams for deltas.
R=read_predictions(fullfile(run_dir,'online_predictions.csv'));
K=read_predictions(fullfile(run_dir,'retention_predictions.csv'));
B=summarize(R,{'scenario','stream_seed','block','method','postprocessing'});
S=summarize(R,{'scenario','stream_seed','method','postprocessing'});
P=summarize(R,{'scenario','method','postprocessing'});
T=summarize(K,{'scenario','stream_seed','method','postprocessing'});
writetable(B,fullfile(run_dir,'online_block_summary.csv'));
writetable(S,fullfile(run_dir,'online_stream_summary.csv'));
writetable(P,fullfile(run_dir,'online_pooled_summary.csv'));
writetable(T,fullfile(run_dir,'retention_summary.csv'));
D=paired_deltas(R);A=aggregate_deltas(D);
writetable(D,fullfile(run_dir,'online_paired_stream_deltas.csv'));
writetable(A,fullfile(run_dir,'online_paired_stream_statistics.csv'));
U=update_audit(run_dir);writetable(U,fullfile(run_dir,'online_updates.csv'));
make_figures(run_dir,B,spec);
info=struct('schema','pra_online_results_v1','prediction_rows',height(R), ...
    'evaluation_episodes',height(unique(R(:,{'scenario','stream_seed','trial_id'}),'rows')), ...
    'independent_streams_per_scenario',numel(spec.stream_seeds),'blocks',spec.blocks, ...
    'retention_prediction_rows',height(K),'update_variant_rows',height(U), ...
    'deployed_variant_updates',sum(U.deployed),'training_failures',sum(U.training_failures), ...
    'development_fixture',spec.development_fixture);
prc_write_json(fullfile(run_dir,'ONLINE_COMPLETE.json'),info);
fid=fopen(fullfile(run_dir,'ONLINE_REPORT.txt'),'w');assert(fid>=0);closer=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'Reference-assisted continual payload identification\nDevelopment fixture: %d\n',spec.development_fixture);
fprintf(fid,'Unknown evaluation episodes: %d; streams/scenario: %d; blocks/stream: %d.\n',info.evaluation_episodes,numel(spec.stream_seeds),spec.blocks);
fprintf(fid,'Order: unknown-object predictions saved -> empty calibration -> independent known reference update -> next block.\n');
fprintf(fid,'Per block: %d unknown probes, 1 empty probe, %d training references, %d validation references.\n',spec.eval_per_block,size(spec.reference_train_theta,1),size(spec.reference_validation_theta,1));
fprintf(fid,'Reference plus empty probing overhead: %d/%d additional probes per unknown probe count.\n',1+size(spec.reference_train_theta,1)+size(spec.reference_validation_theta,1),spec.eval_per_block);
fprintf(fid,'Training: fixed hyperparameters, %d iteration cap, 3 learner seeds; known reference targets only.\n',spec.online_iterations);
fprintf(fid,'Update variants deployed: %d/%d; caught seed training failures: %d. See online_updates.csv for all gates.\n',info.deployed_variant_updates,height(U),info.training_failures);
fprintf(fid,'All unknown scores are from before the current block update. The final block update affects only retention scoring.\n');
fprintf(fid,'All-finite metrics describe candidate predictions including rejected ones; accepted metrics and coverage are reported separately. Missing predictions are counted, never silently removed from denominators.\n');
fprintf(fid,'Raw and common bounded outputs both reported. Units: mass g, COM mm. COM error is planar Euclidean distance.\n');
fprintf(fid,'Paired deltas are candidate MAE(method) minus MAE(control) on common finite episodes within each independent stream; negative favors method. Acceptance disagreement is counted separately.\n');
fprintf(fid,'Across-stream t intervals have only %d independent streams and are descriptive, not a strong significance claim. Objects, stages and learner seeds are not treated as independent streams.\n',numel(spec.stream_seeds));
fprintf(fid,'Retention uses cached held-out nominal inputs with nominal calibration; it is not mechanical recovery. Those inputs do not train or gate updates.\n');
fprintf(fid,'Simulation scope: four-axis robot; mass and planar cx/cz only. Parameter drift is accelerated and held fixed within each probe; no empirical wear-time law, backlash, stiction, flexibility or 3D COM claim.\n');
fprintf(fid,'No indefinite error bound is established by a finite drift experiment. Stationary and separate mechanical/electrical scenarios test specificity.\n\n');
fprintf(fid,'Pooled common-clip candidate metrics (interpret with coverage and stream results):\n');
Q=P(P.postprocessing=="common_clip",:);
for i=1:height(Q)
    fprintf(fid,'%s / %s: mass %.6g g; cx %.6g mm; cz %.6g mm; planar %.6g mm; accepted %d/%d; finite %d/%d\n', ...
        Q.scenario(i),Q.method(i),Q.mass_mae_g(i),Q.cx_mae_mm(i),Q.cz_mae_mm(i),Q.com_mae_mm(i),Q.accepted_n(i),Q.total_n(i),Q.finite_n(i),Q.total_n(i));
end
end

function R=read_predictions(path)
assert(isfile(path),'pra:Summary','Missing prediction file %s.',path);
R=readtable(path,'Delimiter',',','ReadVariableNames',true,'NumHeaderLines',0,'TextType','string');
for f={'finite_prediction','accepted','physical_success','bounds_hit','evaluated_before_current_update'}
    x=R.(f{1});if isstring(x)||iscellstr(x),x=ismember(lower(string(x)),["true","1"]);end
    R.(f{1})=logical(x);
end
end

function S=summarize(R,keys)
[g,S]=findgroups(R(:,keys));names={'mass','cx','cz'};units={'g','mm','mm'};
for i=1:height(S)
    Q=R(g==i,:);p=[Q.mass_est_kg Q.cx_est_m Q.cz_est_m];t=[Q.mass_true_kg Q.cx_true_m Q.cz_true_m];
    finite=all(isfinite(p),2)&all(isfinite(t),2)&Q.finite_prediction;
    accepted=finite&Q.accepted;E=1000*(p-t);
    S.total_n(i)=height(Q);S.finite_n(i)=sum(finite);S.missing_n(i)=sum(~finite);
    S.accepted_n(i)=sum(accepted);S.coverage(i)=mean(accepted);S.physical_failure_n(i)=sum(~Q.physical_success);
    S.bound_hit_n(i)=sum(Q.bounds_hit);S.bound_hit_fraction(i)=mean(Q.bounds_hit);
    for j=1:3
        prefix=names{j};u=units{j};e=E(finite,j);a=E(accepted,j);
        S.([prefix '_mae_' u])(i)=avg(abs(e));S.([prefix '_rmse_' u])(i)=sqrt(avg(e.^2));
        S.([prefix '_p95_' u])(i)=percentile(abs(e),95);S.([prefix '_max_' u])(i)=maximum(abs(e));
        S.([prefix '_accepted_mae_' u])(i)=avg(abs(a));
    end
    d=vecnorm(E(finite,2:3),2,2);da=vecnorm(E(accepted,2:3),2,2);
    S.com_mae_mm(i)=avg(d);S.com_p95_mm(i)=percentile(d,95);S.com_max_mm(i)=maximum(d);
    S.com_accepted_mae_mm(i)=avg(da);S.mass_mape_percent(i)=100*avg(abs((p(finite,1)-t(finite,1))./t(finite,1)));
end
end

function D=paired_deltas(R)
pairs={ 'full','frozen';'full','calibrated_frozen';'full','network_only'; ...
    'full','no_replay';'full','physics_current';'calibrated_frozen','frozen'};
[g,G]=findgroups(R(:,{'scenario','stream_seed','postprocessing'}));rows=struct([]);
for i=1:height(G)
    Q=R(g==i,:);
    for j=1:size(pairs,1)
        X=sortrows(Q(Q.method==string(pairs{j,1}),:),'trial_id');Y=sortrows(Q(Q.method==string(pairs{j,2}),:),'trial_id');
        assert(isequal(X.trial_id,Y.trial_id)&&isequal(X.object_id,Y.object_id),'pra:Pairing','Unpaired observations.');
        t=[X.mass_true_kg X.cx_true_m X.cz_true_m];tx=[Y.mass_true_kg Y.cx_true_m Y.cz_true_m];assert(isequal(t,tx));
        x=[X.mass_est_kg X.cx_est_m X.cz_est_m];y=[Y.mass_est_kg Y.cx_est_m Y.cz_est_m];
        keep=all(isfinite(x),2)&all(isfinite(y),2)&X.finite_prediction&Y.finite_prediction;
        ex=abs(1000*(x(keep,:)-t(keep,:)));ey=abs(1000*(y(keep,:)-t(keep,:)));
        row=struct('scenario',G.scenario(i),'stream_seed',G.stream_seed(i),'postprocessing',G.postprocessing(i), ...
            'method',string(pairs{j,1}),'control',string(pairs{j,2}),'total_n',height(X),'paired_finite_n',sum(keep), ...
            'accepted_both_n',sum(X.accepted&Y.accepted),'acceptance_disagreement_n',sum(xor(X.accepted,Y.accepted)), ...
            'mass_delta_g',avg(ex(:,1)-ey(:,1)),'cx_delta_mm',avg(ex(:,2)-ey(:,2)), ...
            'cz_delta_mm',avg(ex(:,3)-ey(:,3)),'com_delta_mm',avg(vecnorm(ex(:,2:3),2,2)-vecnorm(ey(:,2:3),2,2)));
        rows=append(rows,row);
    end
end
D=struct2table(rows);
end

function A=aggregate_deltas(D)
[g,A]=findgroups(D(:,{'scenario','postprocessing','method','control'}));
fields={'mass_delta_g','cx_delta_mm','cz_delta_mm','com_delta_mm'};
for i=1:height(A)
    Q=D(g==i,:);A.streams_n(i)=height(Q);A.paired_finite_n(i)=sum(Q.paired_finite_n);
    for k=1:numel(fields)
        f=fields{k};v=Q.(f);v=v(isfinite(v));n=numel(v);m=avg(v);sd=NaN;half=NaN;
        A.([f '_valid_streams_n'])(i)=n;
        if n>1,sd=std(v);half=tinv(.975,n-1)*sd/sqrt(n);end
        A.([f '_mean'])(i)=m;A.([f '_sd'])(i)=sd;A.([f '_ci95_lower'])(i)=m-half;A.([f '_ci95_upper'])(i)=m+half;
    end
end
end

function U=update_audit(run_dir)
a=load(fullfile(run_dir,'online_audit.mat'),'events');rows=struct([]);
for i=1:numel(a.events)
    e=a.events(i);names=fieldnames(e.update.variants);
    for j=1:numel(names)
        v=e.update.variants.(names{j});sr=v.seed_reports;
        failures=0;deployed=0;attempts=0;
        if ~isempty(sr),failures=sum(strcmp({sr.reason},'training_failed'));deployed=sum([sr.deployed]);attempts=numel(sr);end
        row=struct('scenario',string(e.scenario),'stream_seed',e.stream_seed,'block',e.block,'variant',string(names{j}), ...
            'calibration_accepted',logical(e.calibration.accepted),'trained',logical(v.trained),'deployed',logical(v.deployed), ...
            'deployed_seed_n',deployed,'seed_attempt_n',attempts,'training_failures',failures,'reason',string(v.reason), ...
            'replay_count_before',v.replay_count_before,'replay_count_after',v.replay_count_after, ...
            'variant_elapsed_s',v.elapsed_s,'block_elapsed_s',e.elapsed_s, ...
            'ensemble_gate_pass',logical(v.ensemble_gate_pass),'old_nominal_loss',v.old_ensemble_nominal_loss, ...
            'candidate_nominal_loss',v.new_ensemble_nominal_loss,'old_reference_loss',v.old_ensemble_reference_loss, ...
            'candidate_reference_loss',v.new_ensemble_reference_loss,'unknown_truth_used',logical(e.update.unknown_truth_used));
        rows=append(rows,row);
    end
end
U=struct2table(rows);assert(~any(U.unknown_truth_used),'pra:TruthLeakage','Unknown truth used.');
end

function make_figures(run_dir,B,spec)
names=["frozen","calibrated_frozen","network_only","full","no_replay","physics_current"];
colors=lines(numel(names));F=fullfile(run_dir,'figures');if ~isfolder(F),mkdir(F);end
for c=1:numel(spec.scenarios)
    scenario=string(spec.scenarios{c});f=figure('Visible','off','Color','w','Position',[100 100 1200 760]);cl=onCleanup(@()close(f));
    tiledlayout(2,2,'TileSpacing','compact');metrics={'mass_mae_g','com_mae_mm','mass_p95_g','coverage'};
    labels={'Mass MAE (g)','Planar COM MAE (mm)','Mass P95 absolute error (g)','Accepted fraction'};
    for k=1:4
        ax=nexttile;hold(ax,'on');
        for m=1:numel(names)
            Q=B(B.scenario==scenario&B.method==names(m)&B.postprocessing=="common_clip",:);
            y=nan(1,spec.blocks);s=y;
            for b=1:spec.blocks,v=Q.(metrics{k})(Q.block==b);v=v(isfinite(v));y(b)=avg(v);if numel(v)>1,s(b)=std(v);end,end
            if any(isfinite(s)),errorbar(ax,1:spec.blocks,y,s,'-o','Color',colors(m,:),'LineWidth',1,'MarkerSize',3,'DisplayName',names(m));
            else,plot(ax,1:spec.blocks,y,'-o','Color',colors(m,:),'DisplayName',names(m));end
        end
        xlabel(ax,'Block (scored before current update)');ylabel(ax,labels{k});grid(ax,'on');
        if k==1,legend(ax,'Location','best','Interpreter','none','FontSize',8);end
    end
    sgtitle(sprintf('%s: mean +/- SD across streams; bounded candidates',scenario),'Interpreter','none');
    exportgraphics(f,fullfile(F,char(scenario+"_continual.png")),'Resolution',180);clear cl
end
end
function v=avg(x),if isempty(x),v=NaN;else,v=mean(x);end,end
function v=percentile(x,p),if isempty(x),v=NaN;else,v=prctile(x,p);end,end
function v=maximum(x),if isempty(x),v=NaN;else,v=max(x);end,end
function A=append(A,row),if isempty(A),A=row;else,A(end+1)=row;end,end
