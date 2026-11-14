function info=pcu_summarize_online(run_dir,spec)
% Prospective all-finite scores, paired STREAM bootstrap, complete cost audit.
R=read_predictions(fullfile(run_dir,'online_predictions.csv'));
K=read_predictions(fullfile(run_dir,'retention_predictions.csv'));
B=summarize(R,{'scenario','stream_seed','block','method','postprocessing'});
S=summarize(R,{'scenario','stream_seed','method','postprocessing'});
P=summarize(R,{'scenario','method','postprocessing'});
T=summarize(K,{'scenario','stream_seed','method','postprocessing'});
writetable(B,fullfile(run_dir,'online_block_summary.csv'));writetable(S,fullfile(run_dir,'online_stream_summary.csv'));
writetable(P,fullfile(run_dir,'online_pooled_summary.csv'));writetable(T,fullfile(run_dir,'retention_summary.csv'));
D=paired_deltas(R);writetable(D,fullfile(run_dir,'online_paired_stream_deltas.csv'));
CI=stream_intervals(D,spec);writetable(CI,fullfile(run_dir,'paired_stream_bootstrap.csv'));
writetable(CI,fullfile(run_dir,'paired_statistics.csv'));
E=summarize(R(R.block==spec.blocks,:),{'scenario','method','postprocessing'});writetable(E,fullfile(run_dir,'terminal_block_summary.csv'));
U=update_audit(run_dir);writetable(U,fullfile(run_dir,'online_updates.csv'));
cost_summary(run_dir,U);
make_figures(run_dir,B,spec);
info=struct('schema','pcu_prospective_results_v1','development_fixture',spec.development_fixture, ...
    'evaluation_episodes',height(unique(R(:,{'scenario','stream_seed','trial_id'}),'rows')), ...
    'prediction_rows',height(R),'update_system_rows',height(U),'deployed_system_updates',sum(U.deployed), ...
    'seed_training_failures',sum(U.seed_training_failures),'independent_streams_per_scenario',numel(spec.stream_seeds), ...
    'fixed_drift_laws',numel(spec.scenarios),'bootstrap_unit','independent object/noise stream, not episode or training seed');
prc_write_json(fullfile(run_dir,'ONLINE_COMPLETE.json'),info);
fid=fopen(fullfile(run_dir,'PROSPECTIVE_REPORT.txt'),'w','n','UTF-8');assert(fid>=0);cl=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'持续更新：独立前瞻压力确认与共同时间轴成本消融\n开发夹具=%d；正式设计为4场景、8独立对象/噪声流、4阶段、1408完整伺服轨迹、512未知事件。\n',spec.development_fixture);
fprintf(fid,'方法沿用冻结PRB；新平滑曲线采用不同轴进度指数且终点与旧曲线相同。四条固定规律不是8条随机磨损规律。\n');
fprintf(fid,'旧开发为8阶段/线性漂移；本研究为4阶段/新曲线，不是旧协议的精确重复。\n');
fprintf(fid,'正式44个episode/流，末阶段未知位于进度33/43至36/43；进度1仅为最后参考测量，不应称未知物覆盖了漂移终点。\n');
fprintf(fid,'Per block: %d unknown probes scored and committed BEFORE 1 empty + %d training + %d independent validation references.\n',spec.eval_per_block,spec.expected_train_references,spec.expected_validation_references);
fprintf(fid,'The last block update has no subsequent unknown probe; it only affects the final nominal network-retention diagnostic.\n');
fprintf(fid,'主组：frozen、empty_only、gated_calibration、gated_full。附组：门控两组的every2/every4；gated_full去历史、去离线训练锚。\n');
fprintf(fid,'Gate uses raw ensemble predictions. Candidate eta and networks deploy as a unit. Rejection retains both.\n');
fprintf(fid,'Required normalized MSE gain: at least %.1f percent AND %.3g absolute. Component MAE tolerances (g/mm/mm): %s.\n', ...
    100*spec.gate_min_relative_improvement,spec.gate_min_absolute_improvement,mat2str(1000*spec.gate_component_mae_tolerance));
fprintf(fid,'Worst-reference normalized squared error tolerance: %.1f percent + %.3g; teacher-accepted reference count cannot fall.\n',100*spec.gate_worst_relative_tolerance,spec.gate_worst_absolute_tolerance);
fprintf(fid,'These are engineering development heuristics, not statistical confidence tests or global error guarantees. Two gate objects provide limited coverage.\n');
fprintf(fid,'Original nominal validation features constrain WEIGHTS at eta0; current known references gate the whole system.\n');
fprintf(fid,'Replay preserves 600 original nominal train inputs plus up to %d past/current training-reference measurements, re-extracted under candidate eta. No validation references enter training.\n',spec.replay_capacity);
fprintf(fid,'All finite raw and common-clipped candidate errors are retained; accepted-only scores, failures, coverage and clipping counts are separate.\n');
fprintf(fid,'Nominal retention is a cached-input, eta0 diagnostic only, not physical wear reversal.\n');
fprintf(fid,'频率预定为block=1:k:4：1,2,3,4 / 1,3 / 1；有后续未知的机会为3/2/1。所有轨迹完全相同，仅限制参考访问和更新，不可声称节省实机采集时间。\n');
fprintf(fid,'去历史保留600离线+当前4参考；去离线保留最多32历史/当前参考。所有组仍有150名义验证输入用于早停和保留门控，故去离线不等于无任何名义锚。\n');
fprintf(fid,'reference_cost_by_block.csv记录实际访问空载/训练/验证计数。训练失败、拒绝、覆盖和原始未裁剪结果均保留。\n');
fprintf(fid,'配对差异区间以整条对象/噪声流重抽样，%d次，8流；描述性95%%区间未作多重比较校正。不可将阶段、物体或网络种子当独立流。\n\n',spec.bootstrap_repeats);
Q=P(P.postprocessing=="common_clip",:);
for i=1:height(Q)
    fprintf(fid,'%s / %s: mass %.6g g, cx %.6g mm, cz %.6g mm, planar %.6g mm; accepted %d/%d; P95 mass %.6g g.\n', ...
        Q.scenario(i),Q.method(i),Q.mass_mae_g(i),Q.cx_mae_mm(i),Q.cz_mae_mm(i),Q.com_mae_mm(i),Q.accepted_n(i),Q.total_n(i),Q.mass_p95_g(i));
end
end
function R=read_predictions(path)
R=readtable(path,'TextType','string');
for f={'finite_prediction','accepted','physical_success','bounds_hit'}
    x=R.(f{1});if isstring(x)||iscellstr(x),x=ismember(lower(string(x)),["true","1"]);end;R.(f{1})=logical(x);
end
end
function S=summarize(R,keys)
[g,S]=findgroups(R(:,keys));names={'mass','cx','cz'};units={'g','mm','mm'};
for i=1:height(S)
    Q=R(g==i,:);p=[Q.mass_est_kg Q.cx_est_m Q.cz_est_m];t=[Q.mass_true_kg Q.cx_true_m Q.cz_true_m];
    finite=all(isfinite(p),2)&all(isfinite(t),2)&Q.finite_prediction;accepted=finite&Q.accepted;E=1000*(p-t);
    S.total_n(i)=height(Q);S.finite_n(i)=sum(finite);S.missing_n(i)=sum(~finite);S.accepted_n(i)=sum(accepted);
    S.coverage(i)=mean(accepted);S.physical_failure_n(i)=sum(~Q.physical_success);S.bound_hit_n(i)=sum(Q.bounds_hit);
    for j=1:3
        prefix=names{j};u=units{j};e=E(finite,j);a=E(accepted,j);
        S.([prefix '_mae_' u])(i)=avg(abs(e));S.([prefix '_rmse_' u])(i)=sqrt(avg(e.^2));
        S.([prefix '_p95_' u])(i)=pct(abs(e),95);S.([prefix '_max_' u])(i)=mx(abs(e));
        S.([prefix '_accepted_mae_' u])(i)=avg(abs(a));
    end
    d=vecnorm(E(finite,2:3),2,2);da=vecnorm(E(accepted,2:3),2,2);
    S.com_mae_mm(i)=avg(d);S.com_rmse_mm(i)=sqrt(avg(d.^2));S.com_p95_mm(i)=pct(d,95);S.com_max_mm(i)=mx(d);S.com_accepted_mae_mm(i)=avg(da);
end
end
function D=paired_deltas(R)
controls=["frozen","empty_only","gated_calibration","gated_full_every2","gated_full_every4", ...
    "gated_calibration_every2","gated_calibration_every4","gated_full_no_history","gated_full_no_offline"];
[g,G]=findgroups(R(:,{'scenario','stream_seed','postprocessing'}));rows=struct([]);
for i=1:height(G)
    Q=R(g==i,:);X=sortrows(Q(Q.method=="gated_full",:),'trial_id');
    for name=controls
        Y=sortrows(Q(Q.method==name,:),'trial_id');assert(isequal(X.trial_id,Y.trial_id)&&isequal(X.object_id,Y.object_id),'prb:Pairing','Unpaired scores.');
        t=[X.mass_true_kg X.cx_true_m X.cz_true_m];x=[X.mass_est_kg X.cx_est_m X.cz_est_m];y=[Y.mass_est_kg Y.cx_est_m Y.cz_est_m];
        keep=all(isfinite(x),2)&all(isfinite(y),2);ex=abs(1000*(x(keep,:)-t(keep,:)));ey=abs(1000*(y(keep,:)-t(keep,:)));
        row=struct('scenario',G.scenario(i),'stream_seed',G.stream_seed(i),'postprocessing',G.postprocessing(i), ...
            'method',"gated_full",'control',name,'total_n',height(X),'paired_finite_n',sum(keep), ...
            'acceptance_disagreement_n',sum(xor(X.accepted,Y.accepted)), ...
            'mass_delta_g',avg(ex(:,1)-ey(:,1)),'cx_delta_mm',avg(ex(:,2)-ey(:,2)),'cz_delta_mm',avg(ex(:,3)-ey(:,3)), ...
            'com_delta_mm',avg(vecnorm(ex(:,2:3),2,2)-vecnorm(ey(:,2:3),2,2)));
        rows=append(rows,row);
    end
end
D=struct2table(rows);
end
function U=update_audit(run_dir)
A=load(fullfile(run_dir,'online_audit.mat'),'events');rows=struct([]);
fid=fopen(fullfile(run_dir,'online_update_reports.jsonl'),'w','n','UTF-8');assert(fid>=0);cl=onCleanup(@()fclose(fid)); %#ok<NASGU>
for i=1:numel(A.events)
    e=A.events(i);fprintf(fid,'%s\n',jsonencode(e));
    V=pcu_variants();v=V(strcmp({V.name},e.variant));
    for name=v.systems
        if strcmp(name{1},'frozen'),continue,end
        s=e.update.systems.(name{1});failures=0;
        for training=fieldnames(s.training).'
            tr=s.training.(training{1});if ~isempty(tr.seed_reports),failures=failures+sum(~[tr.seed_reports.trained]);end
        end
        label=string(name{1});if e.variant~="main",label=label+"_"+e.variant;end
        r=struct('scenario',e.scenario,'stream_seed',e.stream_seed,'block',e.block,'method',label, ...
            'deployed',s.deployed,'eta_changed',s.eta_changed,'network_changed',s.network_changed, ...
            'selected_candidate',string(s.selected_candidate),'reason',string(s.reason), ...
            'old_reference_loss',s.old_reference_loss,'new_reference_loss',s.new_reference_loss, ...
            'old_nominal_loss',s.old_nominal_loss,'new_nominal_loss',s.new_nominal_loss, ...
            'rollback_preserved',s.rollback_preserved,'candidate_count',numel(s.candidates), ...
            'seed_training_failures',failures,'replay_count',e.update.replay_count_after,'variant_total_elapsed_s',e.elapsed_s, ...
            'has_following_unknown_block',e.has_following_unknown_block, ...
            'unknown_truth_used',e.update.unknown_truth_used);
        rows=append(rows,r);
    end
end
U=struct2table(rows);assert(~any(U.unknown_truth_used),'prb:Leakage','Truth entered adaptation.');
end
function make_figures(run_dir,B,spec)
names=["frozen","empty_only","gated_calibration","gated_full"];colors=lines(numel(names));
F=fullfile(run_dir,'figures');if ~isfolder(F),mkdir(F);end
for c=1:numel(spec.scenarios)
    sc=string(spec.scenarios{c});f=figure('Visible','off','Color','w','Position',[100 100 1200 760]);cl=onCleanup(@()close(f));
    tiledlayout(2,2,'TileSpacing','compact');metrics={'mass_mae_g','com_mae_mm','mass_p95_g','coverage'};
    labels={'Mass MAE (g)','Planar COM MAE (mm)','Mass P95 absolute error (g)','Accepted fraction'};
    for k=1:4
        ax=nexttile;hold(ax,'on');
        for m=1:numel(names)
            Q=B(B.scenario==sc&B.method==names(m)&B.postprocessing=="common_clip",:);y=nan(1,spec.blocks);sd=y;
            for b=1:spec.blocks,v=Q.(metrics{k})(Q.block==b);y(b)=avg(v);if numel(v)>1,sd(b)=std(v);end,end
            if any(isfinite(sd)),errorbar(ax,1:spec.blocks,y,sd,'-o','Color',colors(m,:),'DisplayName',names(m),'MarkerSize',3);
            else,plot(ax,1:spec.blocks,y,'-o','Color',colors(m,:),'DisplayName',names(m));end
        end
        xlabel(ax,'Block (before current update)');ylabel(ax,labels{k});grid(ax,'on');
        if k==1,legend(ax,'Location','best','Interpreter','none','FontSize',8);end
    end
    sgtitle(sprintf('Prospective %s: mean +/- SD across object/noise streams',sc),'Interpreter','none');
    exportgraphics(f,fullfile(F,char(sc+"_prospective.png")),'Resolution',160);clear cl
end
end
function v=avg(x),if isempty(x),v=NaN;else,v=mean(x);end,end
function C=stream_intervals(D,spec)
[g,G]=findgroups(D(:,{'scenario','method','control','postprocessing'}));rows=struct([]);
rs=rng;cl=onCleanup(@()rng(rs));rng(spec.bootstrap_seed,'twister'); %#ok<NASGU>
metrics={'mass_delta_g','cx_delta_mm','cz_delta_mm','com_delta_mm'};
for i=1:height(G)
    Q=D(g==i,:);n=height(Q);assert(numel(unique(Q.stream_seed))==n,'pcu:Bootstrap','Duplicate stream unit.');
    index=randi(n,n,spec.bootstrap_repeats);
    for j=1:numel(metrics)
        x=Q.(metrics{j});finite=all(isfinite(x));estimate=mean(x);limits=[NaN NaN];
        if finite&&n>=2,means=mean(x(index),1);limits=prctile(means,[2.5 97.5]);end
        row=struct('scenario',G.scenario(i),'method',G.method(i),'control',G.control(i), ...
            'postprocessing',G.postprocessing(i),'metric',string(metrics{j}),'stream_n',n, ...
            'mean_delta',estimate,'ci95_lower',limits(1),'ci95_upper',limits(2), ...
            'bootstrap_repeats',spec.bootstrap_repeats,'finite_all_streams',finite);
        rows=append(rows,row);
    end
end
C=struct2table(rows);
end
function cost_summary(run_dir,U)
T=readtable(fullfile(run_dir,'reference_cost_by_block.csv'),'TextType','string');
for f={'reference_access_open','has_following_unknown_block'}
    x=T.(f{1});if isstring(x),x=ismember(lower(x),["true","1"]);end;T.(f{1})=logical(x);
end
[g,C]=findgroups(T(:,{'scenario','stream_seed','method'}));
for i=1:height(C)
    Q=T(g==i,:);A=U(U.scenario==C.scenario(i)&U.stream_seed==C.stream_seed(i)&U.method==C.method(i),:);
    C.reference_access_events(i)=sum(Q.reference_access_open);
    C.effective_reference_access_events(i)=sum(Q.reference_access_open&Q.has_following_unknown_block);
    C.empty_observations(i)=sum(Q.empty_observations_used);C.training_labels(i)=sum(Q.training_references_used);C.validation_labels(i)=sum(Q.validation_references_used);
    C.total_known_observations(i)=C.empty_observations(i)+C.training_labels(i)+C.validation_labels(i);
    C.deployed_updates(i)=sum(A.deployed);C.effective_deployed_updates(i)=sum(A.deployed&A.has_following_unknown_block);
    C.deployed_network_updates(i)=sum(A.network_changed);C.effective_network_updates(i)=sum(A.network_changed&A.has_following_unknown_block);
    C.rejected_update_opportunities(i)=sum(~A.deployed);C.seed_training_failures(i)=sum(A.seed_training_failures);
end
writetable(C,fullfile(run_dir,'reference_cost_summary.csv'));
end
function v=pct(x,p),if isempty(x),v=NaN;else,v=prctile(x,p);end,end
function v=mx(x),if isempty(x),v=NaN;else,v=max(x);end,end
function A=append(A,row),if isempty(A),A=row;else,A(end+1)=row;end,end
