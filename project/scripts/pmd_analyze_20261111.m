function result=pmd_analyze_20261111(outputDir)
%PMD_ANALYZE_20261111 Read-only, zero-ODE mechanism analysis of sealed PBD data.
% Simulator truth is diagnostic only. No predictor, inverse fit, training,
% simulation, model selection, acceptance change, or causal intervention.
if nargin<1,outputDir='C:\new\results\pmd_mechanism_20261111_v1';end
outputDir=char(outputDir);outputFile=java.io.File(outputDir);outputDir=char(outputFile.getCanonicalPath());
sourceRun='C:\new\results\pbd_exploration_20261110_v1';
snapshot=fullfile(sourceRun,'source_snapshot');oldpath=path;oldrng=rng;
restore=onCleanup(@()restore_state(oldpath,oldrng)); %#ok<NASGU>
addpath(snapshot,fullfile(snapshot,'src'),fullfile(snapshot,'vendor','bdcl_v29'),'-begin');
assert(~strcmpi(outputDir,sourceRun)&&~startsWith(lower(outputDir),[lower(sourceRun) filesep]), ...
    'pmd:OutputScope','Derivative output must be separate from the source run.');
assert(isfile(fullfile(sourceRun,'COMPLETE.json')),'pmd:Incomplete','Source exploration must be complete.');
manifest=readtable(fullfile(sourceRun,'source_manifest.csv'),'Delimiter',',','TextType','string');
for k=1:height(manifest)
    assert(strcmp(prc_file_hash(fullfile(snapshot,manifest.relative_path(k))),manifest.sha256(k)), ...
        'pmd:SourceIntegrity','Frozen source differs: %s',manifest.relative_path(k));
end
for name={'bpil_predict_power','bpil_static_design','bpil_make_plant','prc_file_hash','pnn_model_hash'}
    assert(startsWith(lower(which(name{1})),lower(snapshot)),'pmd:Path','Wrong function on path: %s',name{1});
end
sources={fullfile(sourceRun,'inputs.mat'),fullfile(sourceRun,'inputs.mat.sha256.json'), ...
    fullfile(sourceRun,'model_bundle.mat'),fullfile(sourceRun,'model_bundle.mat.sha256.json'), ...
    fullfile(sourceRun,'source_manifest.csv'),fullfile(sourceRun,'PREPARED_LOCK.json'), ...
    fullfile(sourceRun,'COMPLETE.json')};
for k=1:156
    f=fullfile(sourceRun,'records',sprintf('trial_%06d.mat',k));sources=[sources {f,[f '.sha256.json']}]; %#ok<AGROW>
end
sourceHashes=hash_files(sources);
lock=jsondecode(fileread(fullfile(sourceRun,'PREPARED_LOCK.json')));
assert(strcmp(sourceHashes(1).sha256,lock.inputs_sha256)&&strcmp(sourceHashes(3).sha256,lock.model_sha256)&& ...
    strcmp(sourceHashes(5).sha256,lock.source_manifest_sha256),'pmd:Lock','Prepared input/model/source lock differs.');
completion=jsondecode(fileread(fullfile(sourceRun,'COMPLETE.json')));
assert(completion.planned_episodes==156&&completion.independent_objects==12,'pmd:Scope','Unexpected source completion scope.');
verify_hashes(completion.outputs);
identity=struct('schema','pmd_identity_v1','source_run',sourceRun,'source_hashes',sourceHashes, ...
    'analysis_source_sha256',prc_file_hash([mfilename('fullpath') '.m']), ...
    'scope','156 existing episodes, 12 exploratory objects; zero generated episodes; frozen models unchanged.');
identityHash=pnn_model_hash(identity);done=fullfile(outputDir,'MECHANISM_COMPLETE.json');
if isfile(done)
    result=jsondecode(fileread(done));assert(strcmp(result.identity_hash,identityHash),'pmd:Identity','Completed analysis inputs changed.');
    verify_hashes(result.outputs);return
end
if ~isfolder(outputDir),mkdir(outputDir);end
write_json_new(fullfile(outputDir,'ANALYSIS_CONTRACT.json'),identity);
sourceCopy=fullfile(outputDir,'analysis_source.m');
if isfile(sourceCopy)
    assert(strcmp(prc_file_hash(sourceCopy),identity.analysis_source_sha256),'pmd:Integrity','Existing analysis source copy differs.');
else
    copyfile([mfilename('fullpath') '.m'],sourceCopy);
end
I=read_immutable(fullfile(sourceRun,'inputs.mat'));B=read_immutable(fullfile(sourceRun,'model_bundle.mat'));
assert(height(I.objects)==12&&numel(I.cells)==13&&numel(B.bundle.methods)==14,'pmd:Scope','Unexpected frozen study dimensions.');
cfg=I.cfg;eta=struct('coefficients',cfg.legacy.power.coefficients);
span=diff(cfg.ident.bounds,1,2).';sigma0=cfg.ident.power_sigma_W;
assert(numel(span)==3&&all(span>0)&&sigma0>0,'pmd:Units','Invalid parameter/noise scaling.');
names={'auxiliary','cold_resistance','thermal_resistance','bridge','current_vs_nominal_torque','shaft','brake','magnetic'};
episodeRows=struct([]);poseRows=struct([]);sampleTables=cell(156,1);checks=struct([]);
for trial=1:156
    saved=read_immutable(fullfile(sourceRun,'records',sprintf('trial_%06d.mat',trial)));r=saved.record;
    k=r.key;T=r.truth;O=r.obs;S=T.spec;C=T.condition;oi=ceil(trial/13);ci=mod(trial-1,13)+1;
    assert(isempty(r.error)&&T.physical_success&&T.energy.pass&&all(O.stationary)&&r.features.usable, ...
        'pmd:SourceValidity','Source episode %d is not a complete usable physical episode.',trial);
    assert(k.trial_id==trial&&k.cell_id==ci&&k.object_id==I.objects.object_id(oi)&& ...
        strcmp(k.family,I.cells(ci).family)&&k.severity==I.cells(ci).severity&&isequaln(k.condition,C), ...
        'pmd:Identity','Source record/grid mismatch.');
    expectedTheta=[I.objects.mass_kg(oi) I.objects.cx_m(oi) I.objects.cz_m(oi)];
    assert(isequal(k.theta,expectedTheta)&&strcmp(k.inputs_sha256,sourceHashes(1).sha256)&& ...
        strcmp(k.model_sha256,sourceHashes(3).sha256)&&strcmp(k.source_manifest_sha256,sourceHashes(5).sha256), ...
        'pmd:Identity','Record payload/input/model/source identity differs.');
    duration=cfg.sim.initial_hold_s+8*(cfg.sim.move_s+cfg.sim.hold_s);
    expectedTimes=(S.dt_record_s:S.dt_record_s:duration).';
    assert(numel(T.t)==numel(expectedTimes)&&max(abs(T.t(:)-expectedTimes))<1e-10&& ...
        isequal(T.t,O.t)&&abs(T.simulated_duration_s-duration)<1e-9&&size(O.plateau_q,1)==8, ...
        'pmd:Sampling','Incomplete or different sample grid.');
    assert(norm(S.K_Nm_per_A-S.K_Vs_per_rad,Inf)<1e-12&& ...
        max(abs(S.R25_ohm./S.K_Nm_per_A.^2-cfg.legacy.power.coefficients(2:5)))<1e-12&& ...
        abs(S.auxiliary_W-cfg.legacy.power.coefficients(1))<1e-12,'pmd:Units','Cold SI calibration identity differs.');
    allTail=false(size(T.t));pose=zeros(size(T.t));window=min(.3,cfg.sim.hold_s/2);sampleCounts=zeros(8,1);
    for j=1:8
        finish=cfg.sim.initial_hold_s+j*(cfg.sim.move_s+cfg.sim.hold_s);
        ix=T.t>=finish-window-1e-10&T.t<=finish+1e-10;
        sampleCounts(j)=sum(ix);assert(~any(allTail&ix),'pmd:Windows','Holding windows overlap.');
        allTail=allTail|ix;pose(ix)=j;
    end
    expectedCount=round(window/S.dt_record_s)+1;
    assert(all(sampleCounts==expectedCount)&&expectedCount==31,'pmd:Windows','Expected exactly 31 samples per holding window.');
    q=T.q(allTail,:);v=T.dq(allTail,:);current=T.current_A(allTail,:);temp=T.temperature_C(allTail,:);
    time=T.t(allTail);pose=pose(allTail);power=T.P(allTail);parts=T.power_parts_W(allTail,:);
    voltage=T.bridge_voltage_V(allTail,:);
    assert(all(isfinite([q v current temp time power parts voltage]),'all'),'pmd:Finite','Nonfinite recorded holding value.');
    assert(isequal(string(T.power_part_names(:)),["bus";"auxiliary";"bridge";"copper";"brake";"shaft";"friction";"cooling"]), ...
        'pmd:LedgerSchema','Unexpected source power ledger order.');
    [nominal,detail]=bpil_predict_power(cfg,q,k.theta,eta);
    R0=S.R25_ohm;K=S.K_Nm_per_A;
    resistance=R0.*C.resistance_scale.*(1+C.alpha_per_K*(temp-S.ambient_C));
    drop=C.bridge_drop_V.*tanh(current/.05)+C.bridge_resistance_ohm.*current;
    di=(voltage-drop-resistance.*current-S.K_Vs_per_rad.*v)./S.L_H;
    magnetic=sum(S.L_H.*current.*di,2); % independent circuit reconstruction
    auxiliary=S.auxiliary_W+C.auxiliary_offset_W+C.auxiliary_ripple_W*sin(2*pi*C.auxiliary_ripple_Hz*time+C.ripple_phase);
    bridge=sum(drop.*current,2);copper=sum(resistance.*current.^2,2);
    shaft=sum(K.*current.*v,2);brake=sum(max(-voltage.*current,0),2);
    component=[auxiliary-S.auxiliary_W, ...
        sum(R0.*(C.resistance_scale-1).*current.^2,2), ...
        sum(R0.*C.resistance_scale.*C.alpha_per_K.*(temp-S.ambient_C).*current.^2,2), ...
        bridge,sum(R0.*(current.^2-(detail.torque_model_Nm./K).^2),2),shaft,brake,magnetic];
    gap=power-nominal;closure=gap-sum(component,2);
    sourceClosure=power-auxiliary-bridge-copper-shaft-brake-magnetic;
    ledgerDiff=max(abs([power-parts(:,1),auxiliary-parts(:,2),bridge-parts(:,3), ...
        copper-parts(:,4),brake-parts(:,5),shaft-parts(:,6)]),[],'all');
    tauDiff=max(abs(T.tau(allTail,:)-K.*current),[],'all');
    assert(max(abs(closure))<1e-8&&max(abs(sourceClosure))<1e-8&&ledgerDiff<1e-8&&tauDiff<1e-10, ...
        'pmd:Closure','Signed SI power identity failed on episode %d.',trial);
    [projection,poseProjection]=local_projection(cfg,O,k.theta,r.features.base,eta,span,sigma0);
    poseComponent=zeros(8,8);poseGap=zeros(8,1);poseNominal=zeros(8,1);
    for j=1:8
        ix=pose==j;poseComponent(j,:)=mean(component(ix,:),1);poseGap(j)=mean(gap(ix));poseNominal(j)=mean(nominal(ix));
        p=identity_row(k,I.cells(ci).condition);p.pose_index=j;p.holding_samples=sum(ix);
        p.first_sample_s=min(time(ix));p.last_sample_s=max(time(ix));p.nominal_power_mean_W=poseNominal(j);
        p.true_power_mean_W=mean(power(ix));p.signed_distortion_mean_W=poseGap(j);
        for h=1:8,p.([names{h} '_mean_W'])=poseComponent(j,h);end
        p.closure_mean_W=mean(closure(ix));p.closure_max_abs_W=max(abs(closure(ix)));
        for h=1:numel(poseProjection.Properties.VariableNames)
            key=poseProjection.Properties.VariableNames{h};p.(key)=poseProjection.(key)(j);
        end
        poseRows=append(poseRows,p);
    end
    observedNominal=bpil_predict_power(cfg,O.q(allTail,:),k.theta,eta);
    sampledObservedGap=zeros(8,1);
    % Use original full-array indices; windows are separated by moving segments.
    fullIndices=find(allTail);
    for j=1:8,ix=pose==j;sampledObservedGap(j)=mean(O.P(fullIndices(ix))-observedNominal(ix));end
    distortionRMS=sqrt(mean(poseGap.^2));
    assert(abs(distortionRMS-r.diagnostics.power_distortion_rms_W)<1e-9&& ...
        abs(sqrt(mean(sampledObservedGap.^2))-r.diagnostics.sampled_observed_power_residual_rms_W)<1e-9, ...
        'pmd:DiagnosticReproduction','Recorded PBD diagnostic not reproduced.');
    e=identity_row(k,I.cells(ci).condition);e.poses=8;e.holding_samples=sum(sampleCounts);e.accepted=logical(r.features.accepted);
    e.true_mass_kg=k.theta(1);e.true_cx_m=k.theta(2);e.true_cz_m=k.theta(3);
    e.signed_distortion_mean_W=mean(poseGap);e.distortion_rms_across_poses_W=distortionRMS;
    e.distortion_relative_rms=distortionRMS/max(sqrt(mean(poseNominal.^2)),eps);
    for h=1:8
        e.([names{h} '_signed_mean_W'])=mean(poseComponent(:,h));
        e.([names{h} '_rms_across_poses_W'])=sqrt(mean(poseComponent(:,h).^2));
    end
    e.closure_max_abs_W=max(abs(closure));e.nominal_condition_at_teacher_all8=r.diagnostics.condition_number;
    e.feature_zmax13=r.diagnostics.feature_zmax13;e.teacher_mass_error_g=r.diagnostics.teacher_mass_error_g;
    e.teacher_com_error_mm=r.diagnostics.teacher_com_error_mm;e.teacher_fit_rmse_W=r.diagnostics.teacher_fit_rmse_W;
    e.teacher_check_rmse_W=r.diagnostics.teacher_check_rmse_W;
    keys=fieldnames(projection);for h=1:numel(keys),e.(keys{h})=projection.(keys{h});end
    episodeRows=append(episodeRows,e);
    ST=table(repmat(k.trial_id,numel(time),1),repmat(k.object_id,numel(time),1),repmat(k.cell_id,numel(time),1),pose,time,nominal,power,gap,closure, ...
        'VariableNames',{'trial_id','object_id','cell_id','pose_index','time_s','nominal_power_W','true_power_W','signed_distortion_W','closure_W'});
    for h=1:8,ST.([names{h} '_W'])=component(:,h);end
    sampleTables{trial}=ST;
    check=struct('trial_id',trial,'object_id',k.object_id,'complete_grid',true,'holding_samples',numel(time), ...
        'sample_closure_max_abs_W',max(abs(closure)),'source_electrical_closure_max_abs_W',max(abs(sourceClosure)), ...
        'source_ledger_reconstruction_max_abs_W',ledgerDiff,'torque_reconstruction_max_abs_Nm',tauDiff, ...
        'pbd_distortion_reproduction_abs_W',abs(distortionRMS-r.diagnostics.power_distortion_rms_W), ...
        'projection_rank',projection.local_fit_rank,'projection_normal_equation_residual',projection.local_normal_equation_residual);
    checks=append(checks,check);
    if mod(trial,13)==0,fprintf('PMD zero-ODE diagnostics: %d/156 records (%d/12 objects)\n',trial,oi);end
end
episodes=struct2table(episodeRows);poses=struct2table(poseRows);samples=vertcat(sampleTables{:});
assert(height(episodes)==156&&numel(unique(episodes.object_id))==12&&height(poses)==1248&&height(samples)==38688, ...
    'pmd:Counts','Full record/pose/sample counts differ.');
for cellid=1:13
    ids=episodes.object_id(episodes.cell_id==cellid);assert(numel(ids)==12&&numel(unique(ids))==12,'pmd:Unit','Cell does not contain all 12 objects.');
end
summary=object_summary(episodes,names);
write_table_new(episodes,fullfile(outputDir,'episode_mechanism.csv'));
write_table_new(poses,fullfile(outputDir,'pose_mechanism.csv'));
write_table_new(samples,fullfile(outputDir,'holding_sample_ledger.csv'));
write_table_new(summary,fullfile(outputDir,'object_summary_by_cell.csv'));
write_table_new(struct2table(checks),fullfile(outputDir,'checks_by_episode.csv'));
plot_mechanism(episodes,names,outputDir);
write_text_new(fullfile(outputDir,'INTERPRETATION_AND_UNITS.txt'),interpretation());
assert(isequaln(sourceHashes,hash_files(sources)),'pmd:InputMutation','A source input/record/seal changed.');
for k=1:height(manifest)
    assert(strcmp(prc_file_hash(fullfile(snapshot,manifest.relative_path(k))),manifest.sha256(k)), ...
        'pmd:SourceIntegrity','Frozen source changed during analysis.');
end
files=dir(fullfile(outputDir,'*'));files=files(~[files.isdir]);outputs=hash_files(cellfun(@(a,b)fullfile(a,b),{files.folder},{files.name},'UniformOutput',false));
result=struct('schema','pmd_mechanism_complete_v1','identity_hash',identityHash,'completed_utc',pnn_utc(), ...
    'source_run',sourceRun,'exploratory_only',true,'post_hoc_diagnostic',true,'new_trajectories',0,'models_trained',0, ...
    'episodes',height(episodes),'objects',12,'poses',height(poses),'holding_samples',height(samples), ...
    'statistical_unit','Object; 12 paired objects per condition. Poses and samples are not independent experimental replicates.', ...
    'all_checks_passed',true,'source_files_unchanged',true,'frozen_source_manifest_verified',true, ...
    'max_sample_closure_abs_W',max([checks.sample_closure_max_abs_W]), ...
    'max_diagnostic_reproduction_abs_W',max([checks.pbd_distortion_reproduction_abs_W]), ...
    'inference','Exact recorded-trajectory algebra plus local nominal-model projection; neither intervention causality nor OOD certification.', ...
    'outputs',outputs);
write_json_new(done,result);
end

function [out,T]=local_projection(cfg,O,theta,teacher,eta,span,sigma0)
q=double(O.plateau_q);p=double(O.plateau_P(:));sigma=max(double(O.plateau_sd_P(:)),sigma0);
[nominal,detail]=bpil_predict_power(cfg,q,theta,eta);J=detail.jacobian;
[~,~,group]=unique(round(q/1e-8)*1e-8,'rows','stable');ng=max(group);
nv=max(1,round(ng*cfg.ident.validation_fraction));held=unique(round(linspace(1,ng,nv)));
valid=ismember(group,held);train=~valid;
assert(ng==8&&sum(train)==6&&sum(valid)==2,'pmd:ProjectionSplit','Expected original six-fit/two-check unique-pose rule.');
A=J(train,:).*span./sigma(train);b=(p(train)-nominal(train))./sigma(train);
singular=svd(A,0);rankA=sum(singular>max(size(A))*eps(max(1,singular(1))));
assert(rankA==3,'pmd:ProjectionRank','True-parameter nominal fit Jacobian is rank deficient.');
u=A\b;delta=(u(:).'.*span);fitted=J*delta(:);gap=p-nominal;remaining=gap-fitted;
normalResidual=norm(A.'*(b-A*u))/max(1,norm(A,'fro')*norm(b));
absorption=NaN;if norm(b)>eps,absorption=norm(A*u)^2/norm(b)^2;end
assert(normalResidual<1e-10&&(~isfinite(absorption)||(absorption>=-1e-10&&absorption<=1+1e-10)), ...
    'pmd:ProjectionAlgebra','Local least-squares projection identity failed.');
trueTeacherBias=(teacher-theta)*1000;localBias=delta*1000;
out=struct('local_fit_rank',rankA,'local_fit_condition_at_truth',singular(1)/singular(3), ...
    'local_fit_min_scaled_singular_at_truth',singular(3),'local_fit_absorption_fraction',absorption, ...
    'local_normal_equation_residual',normalResidual, ...
    'observed_gap_fit_rmse_at_truth_W',sqrt(mean(gap(train).^2)), ...
    'observed_gap_check_rmse_at_truth_W',sqrt(mean(gap(valid).^2)), ...
    'local_remaining_fit_rmse_W',sqrt(mean(remaining(train).^2)), ...
    'local_remaining_check_rmse_W',sqrt(mean(remaining(valid).^2)), ...
    'local_linear_bias_mass_g',localBias(1),'local_linear_bias_cx_mm',localBias(2),'local_linear_bias_cz_mm',localBias(3), ...
    'actual_teacher_bias_mass_g',trueTeacherBias(1),'actual_teacher_bias_cx_mm',trueTeacherBias(2),'actual_teacher_bias_cz_mm',trueTeacherBias(3), ...
    'local_vs_actual_mass_bias_gap_g',localBias(1)-trueTeacherBias(1), ...
    'local_vs_actual_com_bias_gap_mm',norm(localBias(2:3)-trueTeacherBias(2:3)), ...
    'local_step_inside_solver_bounds',all(theta+delta>=cfg.ident.bounds(:,1).'&theta+delta<=cfg.ident.bounds(:,2).'));
T=table(train,valid,sigma,nominal,gap,fitted,remaining, ...
    'VariableNames',{'local_fit_pose','local_check_pose','local_sigma_W','nominal_at_observed_mean_q_and_truth_W', ...
    'observed_gap_at_truth_W','local_absorbed_gap_W','local_remaining_gap_W'});
T.observed_power_mean_W=p;T.nominal_jacobian_mass_W_per_kg=J(:,1);
T.nominal_jacobian_cx_W_per_m=J(:,2);T.nominal_jacobian_cz_W_per_m=J(:,3);
end

function S=object_summary(E,names)
metrics={'signed_distortion_mean_W','distortion_rms_across_poses_W','local_fit_absorption_fraction', ...
    'observed_gap_fit_rmse_at_truth_W','observed_gap_check_rmse_at_truth_W','local_remaining_fit_rmse_W', ...
    'local_remaining_check_rmse_W','local_fit_condition_at_truth','local_fit_min_scaled_singular_at_truth', ...
    'teacher_mass_error_g','teacher_com_error_mm','teacher_fit_rmse_W','teacher_check_rmse_W', ...
    'local_linear_bias_mass_g','actual_teacher_bias_mass_g','local_vs_actual_mass_bias_gap_g','local_vs_actual_com_bias_gap_mm','feature_zmax13'};
for k=1:numel(names),metrics{end+1}=[names{k} '_signed_mean_W'];end
rows=struct([]);
for cellid=1:13
    B=E(E.cell_id==cellid,:);r=struct('cell_id',cellid,'family',B.family(1),'severity',B.severity(1), ...
        'condition',B.condition(1),'objects',height(B),'accepted_objects',sum(B.accepted), ...
        'local_steps_outside_solver_bounds',sum(~B.local_step_inside_solver_bounds),'exploratory_only',true);
    for k=1:numel(metrics)
        x=B.(metrics{k});good=isfinite(x);r.([metrics{k} '_finite_n'])=sum(good);
        r.([metrics{k} '_mean'])=average(x(good));r.([metrics{k} '_min'])=minimum(x(good));r.([metrics{k} '_max'])=maximum(x(good));
    end
    rows=append(rows,r);
end
S=struct2table(rows);
end

function plot_mechanism(E,names,folder)
labels={'Auxiliary offset/ripple','Cold resistance change','Thermal resistance','Bridge loss', ...
    'Current versus nominal torque','Shaft power','Local brake power','Magnetic storage rate'};
colors=lines(8);f=figure('Visible','off','Color','w','Position',[40 40 1600 1350]);cleanup=onCleanup(@()close(f)); %#ok<NASGU>
layout=tiledlayout(f,3,2,'TileSpacing','compact','Padding','compact');
for family=["mechanical","electrical","combined"]
    B=E(E.family==family|E.family=="baseline",:);levels=sort(unique(B.severity));ax=nexttile(layout);hold(ax,'on');handles=gobjects(9,1);
    for h=1:8
        y=B.([names{h} '_signed_mean_W']);scatter(ax,B.severity,y,9,colors(h,:),'filled', ...
            'MarkerFaceAlpha',.14,'MarkerEdgeAlpha',.14,'HandleVisibility','off');m=zeros(size(levels));
        for j=1:numel(levels),m(j)=mean(y(B.severity==levels(j)));end
        handles(h)=plot(ax,levels,m,'-o','Color',colors(h,:),'LineWidth',1.3,'MarkerSize',3);
    end
    total=zeros(size(levels));for j=1:numel(levels),total(j)=mean(B.signed_distortion_mean_W(B.severity==levels(j)));end
    handles(9)=plot(ax,levels,total,'k--o','LineWidth',2,'MarkerSize',4);yline(ax,0,':','HandleVisibility','off');
    xlabel(ax,'Prescribed severity s');ylabel(ax,'Signed mean power contribution (W)');title(ax,char(family));
    grid(ax,'on');set(ax,'YScale','linear');xticks(ax,levels);xlim(ax,[-.025 1.025]);
    if family=="combined",legend(ax,handles,[labels {'Total signed distortion'}],'NumColumns',3,'FontSize',8,'Location','southoutside');end
    ax=nexttile(layout);hold(ax,'on');ids=unique(B.object_id);
    for k=1:numel(ids)
        Q=sortrows(B(B.object_id==ids(k),:),'severity');plot(ax,Q.severity,Q.local_fit_absorption_fraction,'-o', ...
            'Color',[.7 .76 .84],'LineWidth',.7,'MarkerSize',4,'HandleVisibility','off');
    end
    mu=zeros(size(levels));for j=1:numel(levels),mu(j)=mean(B.local_fit_absorption_fraction(B.severity==levels(j)));end
    plot(ax,levels,mu,'-o','Color',[.04 .22 .45],'LineWidth',2,'MarkerSize',6);grid(ax,'on');
    xlabel(ax,'Prescribed severity s');ylabel(ax,'Weighted fit-residual energy absorbed');
    title(ax,'Local nominal-Jacobian projection at true parameters');xticks(ax,levels);xlim(ax,[-.025 1.025]);ylim(ax,[0 1.02]);
end
title(layout,'EXPLORATORY RECORDED-TRAJECTORY DIAGNOSTICS | 12 paired objects | zero new simulations');
subtitle(layout,'Left: dots are objects; lines average object means over eight holding poses. Right: thin lines are objects; thick line is their mean.');
exportgraphics(f,fullfile(folder,'power_ledger_and_local_absorption.png'),'Resolution',180);
exportgraphics(f,fullfile(folder,'power_ledger_and_local_absorption.pdf'),'ContentType','vector');
end

function s=interpretation()
s=strjoin({ ...
'POST HOC EXPLORATORY MECHANISM ANALYSIS. 156 existing complete records, 12 objects, 13 conditions. Zero ODE calls; no predictor refitting or training.'; ...
'The independent statistical unit is an object. Each cell summary equally weights its 12 objects. Eight poses and 31 samples/pose are within-object summaries.'; ...
'Power columns use watts, time seconds, torque N m, current A, resistance ohm, angles radians, and temperature differences kelvin.'; ...
'For each sample P-P0=(aux-a0)+cold_R+thermal_R+bridge+current_vs_nominal_torque+shaft+brake+magnetic.'; ...
'cold_R=sum[R0*(rho-1)*i^2]; thermal_R=sum[R0*rho*alpha*(T-Ta)*i^2]; bridge=sum[(Vdrop*tanh(i/.05)+rbridge*i)*i].'; ...
'current_vs_nominal_torque=sum[R0*(i^2-(tau_nominal(q,theta_true)/K)^2)]. This combines trajectory/dynamic/friction/gravity departures; it is not a pure mechanical causal effect.'; ...
'magnetic=sum[L*i*di/dt], independently reconstructed from the DC voltage equation using recorded bridge voltage, current, velocity and temperature.'; ...
'Components are signed and may cancel. Average the signed sample values within each original holding window, then across its eight poses. Component RMS values DO NOT add to total RMS.'; ...
'The sample ledger closes algebraically against recorded bus power; separate checks reconstruct the source auxiliary, bridge, copper, brake, shaft and torque arrays.'; ...
'These closure checks reuse recorded states and the circuit law. They test bookkeeping consistency and do not constitute a new independent ODE-convergence check.'; ...
'The six-fit/two-check local projection uses the original distinct-pose split, recorded observed mean q/P/SD, nominal calibration, and the true payload only to define a diagnostic Jacobian/residual.'; ...
'Let A=J_fit(theta_true)*parameter_span/sigma and b=(P_observed-P_nominal(theta_true))/sigma. The unconstrained local displacement is span.*(A\b). Absorption=norm(A*(A\b))^2/norm(b)^2.'; ...
'This is a local linear least-squares projection, not a rerun of the bounded nonlinear teacher and not a predictor. It is not Fisher information after nuisance-parameter uncertainty.'; ...
'Local remaining fit/check residuals and differences between local and actual teacher bias are reported to expose linearization limitations. No local result alters the original teacher, gate or learned estimator.'; ...
'All ground truth, motor currents, temperature and torque are explanatory simulation metadata. None enters the frozen deployment features, predictions, model selection or acceptance decisions.'; ...
'The equations attribute recorded power algebraically. They do not identify intervention effects: electrical feedback changes current and motion, grouped nuisance factors co-vary, and severity is not service time.'; ...
'Training-standardized feature magnitudes are descriptive and are not calibrated OOD tests. These analyses cannot establish a precise boundary, general superiority, or single-parameter causality.'; ...
'Nominal all-eight-pose conditioning stored in the original PBD diagnostic is distinguished from the six-fit-pose true-parameter local conditioning computed here.'},newline);
end
function r=identity_row(k,condition)
r=struct('trial_id',k.trial_id,'object_id',k.object_id,'cell_id',k.cell_id,'family',string(k.family), ...
    'severity',k.severity,'condition',string(condition),'exploratory_only',true);
end
function S=read_immutable(file)
sealfile=[file '.sha256.json'];assert(isfile(file)&&isfile(sealfile)&&~isfile([file '.seal_pending.json']), ...
    'pmd:Seal','Input must have a committed seal; analysis never repairs inputs.');
seal=jsondecode(fileread(sealfile));assert(strcmp(seal.sha256,prc_file_hash(file)),'pmd:Seal','Input hash differs.');S=load(file);
end
function H=hash_files(files)
H=repmat(struct('path','','sha256',''),numel(files),1);
for k=1:numel(files),assert(isfile(files{k}),'pmd:Missing','Missing source %s',files{k});H(k)=struct('path',files{k},'sha256',prc_file_hash(files{k}));end
end
function verify_hashes(H)
for k=1:numel(H),assert(isfile(H(k).path)&&strcmp(prc_file_hash(H(k).path),H(k).sha256),'pmd:Integrity','Completed artifact changed.');end
end
function x=append(x,r),if isempty(x),x=r;else,x(end+1)=r;end,end
function x=average(v),x=NaN;if ~isempty(v),x=mean(v);end,end
function x=minimum(v),x=NaN;if ~isempty(v),x=min(v);end,end
function x=maximum(v),x=NaN;if ~isempty(v),x=max(v);end,end
function restore_state(oldpath,oldrng),path(oldpath);rng(oldrng);end
function write_table_new(T,file)
t=[file '.' char(java.util.UUID.randomUUID()) '.tmp'];writetable(T,t,'FileType','text');commit(t,file);
end
function write_json_new(file,value),write_text_new(file,jsonencode(value,PrettyPrint=true));end
function write_text_new(file,value)
t=[file '.' char(java.util.UUID.randomUUID()) '.tmp'];fid=fopen(t,'w','n','UTF-8');assert(fid>=0,'pmd:Write','Cannot create %s.',t);
c=onCleanup(@()fclose(fid));fprintf(fid,'%s\n',value);clear c;commit(t,file);
end
function commit(t,file)
if isfile(file),assert(strcmp(prc_file_hash(file),prc_file_hash(t)),'pmd:Integrity','Existing derivative differs: %s',file);delete(t);
else,[ok,msg]=movefile(t,file);assert(ok,'pmd:Write','%s',msg);end
end
