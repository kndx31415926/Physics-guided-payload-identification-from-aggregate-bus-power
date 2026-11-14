function info=pbd_analyze(runDir,D,bundle,rows,options)
%PBD_ANALYZE Immutable cumulative snapshots of a small boundary exploration.
% No fitting, model selection, gate changes, or confirmatory decision occurs.
% Required rows: trial_id, object_id, cell_id, family, severity and diagnostics.
% Call only after an entire 13-cell object block has been sealed.
R=validate_rows(D,bundle,rows);nobjects=numel(unique(R.object_id));
outdir=fullfile(char(runDir),'snapshots',sprintf('snapshot_%03d',nobjects));
if ~isfolder(outdir),mkdir(outdir);end
identity=struct('schema','pbd_analysis_identity_v1','dataset_hash',pnn_model_hash(D), ...
    'bundle_hash',pnn_model_hash(bundle),'diagnostic_hash',pnn_model_hash(table2struct(R)), ...
    'options',options,'analysis_source_sha256',prc_file_hash([mfilename('fullpath') '.m']));
identity_hash=pnn_model_hash(identity);done=fullfile(outdir,'SNAPSHOT_COMPLETE.json');
if isfile(done)
    info=jsondecode(fileread(done));
    assert(strcmp(info.identity_hash,identity_hash),'pbd:SnapshotIdentity','Completed snapshot input changed.');
    verify_outputs(info.outputs);return
end
contract=fullfile(outdir,'EXPLORATORY_CONTRACT.mat');
if pnn_checkpoint('exists',contract)
    prior=pnn_checkpoint('read',contract);
    assert(isequaln(prior.identity,identity),'pbd:SnapshotIdentity','Incomplete snapshot input changed.');
else
    pnn_checkpoint('write',contract,struct('identity',identity));
end
% This exact frozen evaluator is also used by the parent experiment.
evaluation=psx_evaluate(D,bundle,options,fullfile(outdir,'evaluation'));
E=pnn_checkpoint('read',fullfile(outdir,'evaluation','evaluation_matrices.mat'));
methods=string(E.method_names(:));main=find(methods=="ridgeSkipNN13");
assert(isscalar(main),'pbd:Primary','Frozen ridgeSkipNN13 must be present exactly once.');
write_table_new(R,fullfile(outdir,'episode_diagnostics.csv'));
write_table_new(diagnostic_summary(R),fullfile(outdir,'diagnostic_summary.csv'));
[paired,candidates,mechanism]=paired_points(D,R,E,main);
write_table_new(paired,fullfile(outdir,'paired_object_deltas.csv'));
write_table_new(mechanism,fullfile(outdir,'mechanism_object_steps.csv'));
write_table_new(interaction_contrasts(D,R,E),fullfile(outdir,'interaction_contrasts.csv'));
write_table_new(candidates,fullfile(outdir,'candidate_grid.csv'));
candidate_document=struct('schema','pbd_boundary_candidates_v1','exploratory_only',true, ...
    'unique_objects',nobjects,'primary_method','ridgeSkipNN13', ...
    'delta_definition','Primary error minus each independently named baseline; negative favors primary.', ...
    'classification','Observed point estimates at sampled cells only. Each baseline and output is assessed separately.', ...
    'limitations',{{'Small exploratory sample; no superiority or equivalence conclusion.', ...
    'No interpolation, continuity, monotonicity, precise boundary, or unsampled-region assertion.', ...
    'The two-output point flag is descriptive, not a statistical decision or a model-selection rule.', ...
    'Finite pairs include accepted and rejected predictions; missing pairs remain visible in coverage.', ...
    'Common clipping is a secondary calculation; raw failures are never repaired by clipping.', ...
    'Intervals from the common evaluator are exploratory and are not used in these candidate labels.'}}, ...
    'cells',table2struct(candidates));
write_json_new(fullfile(outdir,'boundary_candidates.json'),candidate_document);
plotdir=fullfile(outdir,'plots');if ~isfolder(plotdir),mkdir(plotdir);end
plot_all(D,R,E,paired,nobjects,plotdir);
write_report(outdir,R,candidates,options,evaluation);
listing=dir(fullfile(outdir,'**','*'));listing=listing(~[listing.isdir]);
outputs=repmat(struct('path','','sha256',''),numel(listing),1);
for k=1:numel(listing)
    outputs(k).path=fullfile(listing(k).folder,listing(k).name);
    outputs(k).sha256=prc_file_hash(outputs(k).path);
end
info=struct('schema','pbd_snapshot_complete_v1','identity_hash',identity_hash, ...
    'completed_utc',pnn_utc(),'exploratory_only',true,'unique_objects',nobjects, ...
    'episodes',height(R),'methods',numel(methods),'cells_per_object',13, ...
    'primary_method','ridgeSkipNN13','evaluation',evaluation,'outputs',outputs, ...
    'conclusion_scope','Point estimates only at discrete sampled cells; no confirmatory boundary or superiority claim.');
write_json_new(done,info);
end

function R=validate_rows(D,bundle,rows)
if istable(rows),R=rows;else,assert(isstruct(rows),'pbd:Rows','Rows must be a table or struct array.');R=struct2table(rows);end
required={'trial_id','object_id','cell_id','family','severity','physical_success','feature_usable', ...
    'accepted','energy_pass','stationary','power_distortion_rms_W','power_distortion_relative', ...
    'teacher_mass_error_g','teacher_com_error_mm','teacher_fit_rmse_W','teacher_check_rmse_W', ...
    'condition_number','singular_min_scaled','feature_zmax13','feature_zrms13','max_temperature_C', ...
    'observed_power_residual_rms_W', ...
    'mean_bridge_loss_W','mean_copper_loss_W','plateau_speed_rms_max','wall_s'};
assert(all(ismember(required,R.Properties.VariableNames)),'pbd:Rows','Required episode diagnostic fields missing.');
assert(height(R)==size(D.theta,1)&&height(R)>=13,'pbd:Rows','Diagnostics must match every dataset row.');
assert(numel(unique(R.trial_id))==height(R),'pbd:Rows','Diagnostic trial IDs must be unique.');
[present,order]=ismember(D.trial_id(:),R.trial_id);
assert(all(present),'pbd:Rows','Diagnostics missing a trial ID.');R=R(order,:);
assert(isequal(D.object_id(:),R.object_id(:)),'pbd:Rows','Diagnostic object IDs differ from data.');
R.family=string(R.family);R.condition=string(D.condition(:));
assert(all(isfinite(R.severity)),'pbd:Rows','Severity must be finite.');
assert(all(ismember(R.family,["baseline","mechanical","electrical","combined"])),'pbd:Rows','Unknown family.');
objects=unique(R.object_id);reference=[];
for k=1:numel(objects)
    ix=R.object_id==objects(k);S=R(ix,:);
    assert(height(S)==13&&numel(unique(S.cell_id))==13&&numel(unique(S.condition))==13, ...
        'pbd:IncompleteBlock','Analysis requires exactly all 13 cells for every included object.');
    assert(sum(S.family=="baseline"&S.severity==0)==1,'pbd:Grid','One baseline severity-zero cell required.');
    for f=["mechanical","electrical","combined"]
        x=sort(S.severity(S.family==f));
        assert(isequal(x(:),[.1;.25;.5;1]),'pbd:Grid','Each family requires severity .1, .25, .5, 1.');
    end
    grid=sortrows(S(:,{'cell_id','family','severity','condition'}),'cell_id');
    if isempty(reference),reference=grid;
    else,assert(isequaln(reference,grid),'pbd:Grid','Object cell definitions differ.');end
end
assert(numel(bundle.methods)==14,'pbd:Methods','The frozen exploratory bundle must contain all 14 methods.');
required_methods=["ridgeSkipNN13","ridge13","ridgeAug","interactionRidge","affine_fixed","affine_selected"];
assert(all(ismember(required_methods,string({bundle.methods.name}))),'pbd:Methods','Required frozen methods missing.');
end

function T=diagnostic_summary(R)
fields={'power_distortion_rms_W','power_distortion_relative','teacher_mass_error_g','teacher_com_error_mm', ...
    'teacher_fit_rmse_W','teacher_check_rmse_W','condition_number','singular_min_scaled','feature_zmax13','feature_zrms13', ...
    'observed_power_residual_rms_W', ...
    'max_temperature_C','mean_bridge_loss_W','mean_copper_loss_W','plateau_speed_rms_max','wall_s'};
flags={'physical_success','feature_usable','accepted','energy_pass','stationary'};
cells=unique(R.cell_id,'stable');out=struct([]);
for k=1:numel(cells)
    S=R(R.cell_id==cells(k),:);
    r=struct('cell_id',cells(k),'family',S.family(1),'severity',S.severity(1), ...
        'condition',S.condition(1),'planned_n',height(S),'exploratory_only',true);
    for j=1:numel(flags)
        x=S.(flags{j});r.([flags{j} '_pass_n'])=sum(isfinite(x)&x==1);
        r.([flags{j} '_fail_or_missing_n'])=sum(~isfinite(x)|x~=1);
    end
    for j=1:numel(fields)
        x=S.(fields{j});good=isfinite(x);
        r.([fields{j} '_finite_n'])=sum(good);r.([fields{j} '_mean'])=average(x(good));
        r.([fields{j} '_min'])=minimum(x(good));r.([fields{j} '_max'])=maximum(x(good));
    end
    out=append(out,r);
end
T=struct2table(out);
end

function [T,C,M]=paired_points(D,R,E,main)
methods=string(E.method_names(:));tables=cell(2*(numel(methods)-1),1);q=0;out=struct([]);
physics=find(methods=="physics6");ridge=find(methods=="ridge13");
assert(isscalar(physics)&&isscalar(ridge),'pbd:Methods','Physics6 and ridge13 required for mechanism contrasts.');
raw_primary=E.raw_predictions(:,:,main);raw_ridge=E.raw_predictions(:,:,ridge);
correction=(raw_primary-raw_ridge)*1000;target=(D.theta-raw_ridge)*1000;
correction_valid=all(isfinite(raw_primary),2)&all(isfinite(raw_ridge),2);
correction(~correction_valid,:)=NaN;target(~correction_valid,:)=NaN;mechanism_tables=cell(2,1);
for post=1:2
    processing="raw";V=E.raw_predictions;if post==2,processing="common_clip";V=E.clipped_predictions;end
    [ma,co,finite]=all_errors(V,D.theta);cells=unique(R.cell_id,'stable');
    step1=finite(:,physics)&finite(:,ridge);step2=finite(:,ridge)&finite(:,main);
    step1_mass=ma(:,ridge)-ma(:,physics);step1_com=co(:,ridge)-co(:,physics);
    step2_mass=ma(:,main)-ma(:,ridge);step2_com=co(:,main)-co(:,ridge);
    step1_mass(~step1)=NaN;step1_com(~step1)=NaN;step2_mass(~step2)=NaN;step2_com(~step2)=NaN;
    MS=R(:,{'trial_id','object_id','cell_id','family','severity','condition'});n=height(MS);
    MS.postprocessing=repmat(processing,n,1);MS.physics6_to_ridge13_paired_finite=step1;
    MS.ridge13_to_primary_paired_finite=step2;MS.all_three_steps_finite=step1&step2;
    MS.physics6_to_ridge13_mass_delta_g=step1_mass;MS.physics6_to_ridge13_com_delta_mm=step1_com;
    MS.ridge13_to_primary_mass_delta_g=step2_mass;MS.ridge13_to_primary_com_delta_mm=step2_com;
    MS.raw_primary_minus_ridge13_mass_g=correction(:,1);MS.raw_primary_minus_ridge13_cx_mm=correction(:,2);
    MS.raw_primary_minus_ridge13_cz_mm=correction(:,3);MS.raw_primary_minus_ridge13_com_norm_mm=vecnorm(correction(:,2:3),2,2);
    MS.raw_mass_correction_target_alignment_g2=correction(:,1).*target(:,1);
    MS.raw_com_correction_target_alignment_mm2=sum(correction(:,2:3).*target(:,2:3),2);
    MS.exploratory_only=true(n,1);mechanism_tables{post}=MS;
    for b=1:numel(methods)
        if b==main,continue;end
        q=q+1;paired=finite(:,main)&finite(:,b);
        mass_delta=ma(:,main)-ma(:,b);com_delta=co(:,main)-co(:,b);
        mass_delta(~paired)=NaN;com_delta(~paired)=NaN;
        T0=R(:,{'trial_id','object_id','cell_id','family','severity','condition'});
        n=height(T0);T0.method=repmat(methods(main),n,1);T0.baseline=repmat(methods(b),n,1);
        T0.postprocessing=repmat(processing,n,1);T0.paired_finite=paired;
        T0.primary_finite=finite(:,main);T0.baseline_finite=finite(:,b);
        T0.primary_accepted=E.accepted(:,main);T0.baseline_accepted=E.accepted(:,b);
        T0.primary_bounds_hit=E.bounds_hit(:,main);T0.baseline_bounds_hit=E.bounds_hit(:,b);
        T0.primary_mass_error_g=ma(:,main);T0.baseline_mass_error_g=ma(:,b);
        T0.primary_com_error_mm=co(:,main);T0.baseline_com_error_mm=co(:,b);
        T0.mass_delta_g=mass_delta;T0.com_delta_mm=com_delta;
        extra=MS(:,7:end);extra.postprocessing=[];T0=[T0 extra];tables{q}=T0;
        for k=1:numel(cells)
            ix=R.cell_id==cells(k);ok=ix&paired;first=find(ix,1);
            dm=average(mass_delta(ok));dc=average(com_delta(ok));
            r=struct('cell_id',cells(k),'family',R.family(first),'severity',R.severity(first), ...
                'condition',R.condition(first),'method',methods(main),'baseline',methods(b), ...
                'postprocessing',processing,'planned_n',sum(ix),'paired_n',sum(ok), ...
                'pair_coverage',sum(ok)/sum(ix),'all_planned_pairs_finite',all(paired(ix)), ...
                'primary_failed_n',sum(ix&~finite(:,main)),'baseline_failed_n',sum(ix&~finite(:,b)), ...
                'primary_accepted_n',sum(ix&E.accepted(:,main)),'baseline_accepted_n',sum(ix&E.accepted(:,b)), ...
                'primary_bounds_hit_n',sum(ix&E.bounds_hit(:,main)),'baseline_bounds_hit_n',sum(ix&E.bounds_hit(:,b)), ...
                'mass_delta_mean_g',dm,'com_delta_mean_mm',dc, ...
                'mass_point_direction',direction(dm),'com_point_direction',direction(dc), ...
                'finite_pair_subset_both_deltas_negative',isfinite(dm)&&isfinite(dc)&&dm<0&&dc<0, ...
                'both_negative_complete_pair_point_candidate',all(paired(ix))&&isfinite(dm)&&isfinite(dc)&&dm<0&&dc<0, ...
                'exploratory_only',true);
            out=append(out,r);
        end
    end
end
T=vertcat(tables{:});C=struct2table(out);M=vertcat(mechanism_tables{:});
end

function T=interaction_contrasts(D,R,E)
% Discrete factorial contrast of grouped factors, not a parameter attribution.
methods=string(E.method_names(:));objects=unique(R.object_id);out=struct([]);
for post=1:2
    processing="raw";V=E.raw_predictions;if post==2,processing="common_clip";V=E.clipped_predictions;end
    [mass,com,finite]=all_errors(V,D.theta);
    for o=1:numel(objects)
        obj=R.object_id==objects(o);zero=find(obj&R.family=="baseline");
        for s=[.1 .25 .5 1]
            mech=find(obj&R.family=="mechanical"&R.severity==s);
            elec=find(obj&R.family=="electrical"&R.severity==s);
            comb=find(obj&R.family=="combined"&R.severity==s);indices=[comb mech elec zero];
            for j=1:numel(methods)
                complete=all(finite(indices,j));dm=NaN;dc=NaN;
                if complete,dm=mass(comb,j)-mass(mech,j)-mass(elec,j)+mass(zero,j);dc=com(comb,j)-com(mech,j)-com(elec,j)+com(zero,j);end
                p=R.power_distortion_rms_W(indices);pcontrast=NaN;
                if all(isfinite(p)),pcontrast=p(1)-p(2)-p(3)+p(4);end
                observed=R.observed_power_residual_rms_W(indices);ocontrast=NaN;
                if all(isfinite(observed)),ocontrast=observed(1)-observed(2)-observed(3)+observed(4);end
                r=struct('object_id',objects(o),'severity',s,'method',methods(j),'postprocessing',processing, ...
                    'baseline_trial_id',R.trial_id(zero),'mechanical_trial_id',R.trial_id(mech), ...
                    'electrical_trial_id',R.trial_id(elec),'combined_trial_id',R.trial_id(comb), ...
                    'all_four_predictions_finite',complete,'all_four_accepted',all(E.accepted(indices,j)), ...
                    'mass_error_interaction_g',dm,'com_error_interaction_mm',dc, ...
                    'power_distortion_rms_interaction_W',pcontrast,'observed_power_residual_rms_interaction_W',ocontrast, ...
                    'exploratory_only',true);
                out=append(out,r);
            end
        end
    end
end
T=struct2table(out);
end

function plot_all(D,R,E,paired,nobjects,plotdir)
methods=string(E.method_names(:));colors=lines(numel(methods));
for post=1:2
    processing="raw";V=E.raw_predictions;if post==2,processing="common_clip";V=E.clipped_predictions;end
    [mass,com]=all_errors(V,D.theta);
    for family=["mechanical","electrical","combined"]
        ix=R.family==family|R.family=="baseline";levels=sort(unique(R.severity(ix)));
        f=figure('Visible','off','Color','w','Position',[50 50 1400 900]);clean=onCleanup(@()close(f));
        layout=tiledlayout(f,2,1,'TileSpacing','compact','Padding','compact');
        for metric=1:2
            ax=nexttile(layout);hold(ax,'on');Y=mass;yl='Absolute mass error (g)';
            if metric==2,Y=com;yl='Planar CoM distance error (mm)';end
            handles=gobjects(numel(methods),1);
            for j=1:numel(methods)
                good=ix&isfinite(Y(:,j));scatter(ax,R.severity(good),Y(good,j),12,colors(j,:), ...
                    'filled','MarkerFaceAlpha',.18,'MarkerEdgeAlpha',.18,'HandleVisibility','off');
                y=nan(size(levels));
                for k=1:numel(levels),x=Y(ix&R.severity==levels(k),j);y(k)=average(x(isfinite(x)));end
                handles(j)=plot(ax,levels,y,'-o','Color',colors(j,:),'LineWidth',1.3,'MarkerSize',4);
            end
            set(ax,'YScale','linear');grid(ax,'on');xlabel(ax,'Prescribed severity s (baseline at 0)');ylabel(ax,yl);
            xticks(ax,levels);xlim(ax,[-.025 1.025]);
            title(ax,sprintf('%s | %s | %s',family,processing,yl),'Interpreter','none');
            if metric==2
                lg=legend(ax,handles,cellstr(methods),'Interpreter','none','NumColumns',4,'Location','southoutside');
                lg.FontSize=8;
            end
        end
        title(layout,sprintf('EXPLORATORY ONLY | %d objects | dots: individual objects; lines: finite-row means',nobjects));
        subtitle(layout,'All finite rows, including gate rejections. Failures and coverage are retained in the CSV files.');
        exportgraphics(f,fullfile(plotdir,sprintf('%s_%s_all_method_errors.png',family,processing)),'Resolution',150);clear clean
        plot_differences(paired,family,processing,["ridge13","ridgeAug","interactionRidge"],nobjects,plotdir,'ridge');
        plot_differences(paired,family,processing,["affine_fixed","affine_selected"],nobjects,plotdir,'affine');
    end
end
plot_diagnostics(R,nobjects,plotdir);
end

function plot_differences(T,family,processing,baselines,nobjects,plotdir,group)
f=figure('Visible','off','Color','w','Position',[50 50 1300 320*numel(baselines)]);clean=onCleanup(@()close(f)); %#ok<NASGU>
layout=tiledlayout(f,numel(baselines),2,'TileSpacing','compact','Padding','compact');
for b=1:numel(baselines)
    S=T((T.family==family|T.family=="baseline")&T.postprocessing==processing&T.baseline==baselines(b),:);
    objects=unique(S.object_id);levels=sort(unique(S.severity));
    for metric=1:2
        ax=nexttile(layout);hold(ax,'on');field='mass_delta_g';yl='Primary - baseline mass error (g)';
        if metric==2,field='com_delta_mm';yl='Primary - baseline CoM error (mm)';end
        for k=1:numel(objects)
            B=sortrows(S(S.object_id==objects(k),:),'severity');
            plot(ax,B.severity,B.(field),'-o','Color',[.73 .78 .84],'LineWidth',.65,'MarkerSize',3,'HandleVisibility','off');
        end
        means=nan(size(levels));
        for k=1:numel(levels),x=S.(field)(S.severity==levels(k));means(k)=average(x(isfinite(x)));end
        plot(ax,levels,means,'-o','Color',[.08 .24 .48],'LineWidth',2,'MarkerSize',6);
        yline(ax,0,'--','Color',[.5 .15 .15],'LineWidth',1);set(ax,'YScale','linear');grid(ax,'on');
        xticks(ax,levels);xlim(ax,[-.025 1.025]);xlabel(ax,'Prescribed severity s (baseline at 0)');ylabel(ax,yl);
        title(ax,sprintf('ridgeSkipNN13 versus %s',baselines(b)),'Interpreter','none');
    end
end
title(layout,sprintf('EXPLORATORY ONLY | %s | %s | %d objects | negative favors primary',family,processing,nobjects));
subtitle(layout,'Thin lines: paired objects; thick line: finite-pair mean. No confidence or boundary decision.');
exportgraphics(f,fullfile(plotdir,sprintf('%s_%s_%s_point_deltas.png',family,processing,group)),'Resolution',150);
end

function plot_diagnostics(R,nobjects,plotdir)
fields={'power_distortion_rms_W','power_distortion_relative','teacher_mass_error_g','teacher_com_error_mm', ...
    'feature_zmax13','condition_number','singular_min_scaled','observed_power_residual_rms_W'};
labels={'Power distortion RMS (W)','Relative power distortion','Teacher mass error (g)', ...
    'Teacher CoM error (mm)','Maximum absolute standardized feature','Condition number', ...
    'Minimum scaled singular value','Observed power residual RMS (W)'};
for family=["mechanical","electrical","combined"]
    S=R(R.family==family|R.family=="baseline",:);objects=unique(S.object_id);levels=sort(unique(S.severity));
    f=figure('Visible','off','Color','w','Position',[50 50 1300 1350]);clean=onCleanup(@()close(f));
    layout=tiledlayout(f,4,2,'TileSpacing','compact','Padding','compact');
    for j=1:numel(fields)
        ax=nexttile(layout);hold(ax,'on');
        for k=1:numel(objects)
            B=sortrows(S(S.object_id==objects(k),:),'severity');y=B.(fields{j});y(~isfinite(y))=NaN;
            plot(ax,B.severity,y,'-o','Color',[.73 .78 .84],'LineWidth',.65,'MarkerSize',3);
        end
        means=nan(size(levels));
        for k=1:numel(levels),y=S.(fields{j})(S.severity==levels(k));means(k)=average(y(isfinite(y)));end
        plot(ax,levels,means,'-o','Color',[.08 .24 .48],'LineWidth',2,'MarkerSize',6);
        grid(ax,'on');set(ax,'YScale','linear');xticks(ax,levels);xlim(ax,[-.025 1.025]);
        xlabel(ax,'Prescribed severity s (baseline at 0)');ylabel(ax,labels{j});title(ax,labels{j});
    end
    title(layout,sprintf('EXPLORATORY DIAGNOSTICS | %s | %d objects | finite values only',family,nobjects));
    subtitle(layout,'Thin lines: objects; thick line: finite mean. Missing and failed diagnostic counts appear in diagnostic_summary.csv.');
    exportgraphics(f,fullfile(plotdir,sprintf('%s_diagnostics.png',family)),'Resolution',150);clear clean
end
end

function write_report(outdir,R,C,options,evaluation)
lines={sprintf('EXPLORATORY SNAPSHOT: %d complete objects, %d episodes, 13 cells/object.',numel(unique(R.object_id)),height(R)); ...
    'This is a new finite-grid exploration with locked models. It is not an additional confirmatory sample.'; ...
    'All 14 frozen methods are evaluated by the unchanged psx_evaluate implementation.'; ...
    'Primary: ridgeSkipNN13. Each named baseline is assessed separately; no pooled all-baseline winner.'; ...
    'Point delta = primary error minus baseline error. Negative values favor primary for that output only.'; ...
    'Both negative point deltas with full planned finite pairing identify only a sampled candidate cell, not a proved advantage region.'; ...
    'No interpolation, precise crossing, monotonicity, continuity, unsampled-region, or general superiority assertion is made.'; ...
    'Raw all-finite error is primary; accepted-only summaries are separately available from the evaluator.'; ...
    'Common-clipped predictions are secondary. A raw nonfinite prediction remains failed after clipping.'; ...
    'Every planned row remains in the matrices, predictions CSV, diagnostics CSV and paired-object CSV.'; ...
    'Plots use linear axes, retain signed differences, and show individual objects. They do not filter on acceptance.'; ...
    'Finite-value means can be conditional on method-specific failure; compare finite/accepted coverage before interpreting them.'; ...
    sprintf('The common evaluator uses %d bootstrap replicates (smoke_test=%d).',options.bootstrap_replicates,options.smoke_test); ...
    'All bootstrap intervals are exploratory only. With very few objects they may be degenerate or unstable.'; ...
    'Intervals are retained for audit but never used for candidate labels, model selection, stopping, or a superiority claim.'; ...
    'Severity s denotes the prescribed grouped perturbation path, not service time or a linear physical degradation measure.'; ...
    'Mechanism steps use output error changes: ridge13 minus physics6, then primary minus ridge13. Negative means lower error.'; ...
    'Raw primary-minus-ridge13 correction is reported in grams and millimeters; positive target alignment points toward truth at ridge13.'; ...
    'Truth is used only for this post hoc diagnostic. These fields are never supplied to the predictors or used to tune models.'; ...
    'Interaction contrast = combined - mechanical - electrical + baseline for the same object and prescribed s.'; ...
    'Interaction of error magnitudes or power-distortion RMS is a descriptive grouped-factor contrast, not a causal single-parameter attribution.'; ...
    'Matched object seeds support paired comparisons; a failed trajectory may consume noise draws differently, so pointwise noise identity is not asserted.'; ...
    sprintf('Physical success: %d/%d; feature usable: %d/%d; accepted: %d/%d.', ...
    sum(R.physical_success==1),height(R),sum(R.feature_usable==1),height(R),sum(R.accepted==1),height(R)); ...
    sprintf('Retained candidate-grid records: %d (all cells, all other baselines, raw and clip).',height(C)); ...
    ['Evaluation identity: ' char(evaluation.identity_hash)]; ...
    'A completed snapshot is immutable. Later complete object blocks are written to a new snapshot directory.'};
write_text_new(fullfile(outdir,'EXPLORATORY_README.txt'),strjoin(lines,newline));
end

function [mass,com,finite]=all_errors(V,theta)
n=size(theta,1);nm=size(V,3);mass=nan(n,nm);com=mass;finite=false(n,nm);
for j=1:nm
    p=V(:,:,j);finite(:,j)=all(isfinite(p),2);
    mass(:,j)=abs(p(:,1)-theta(:,1))*1000;com(:,j)=sqrt(sum((p(:,2:3)-theta(:,2:3)).^2,2))*1000;
    mass(~finite(:,j),j)=NaN;com(~finite(:,j),j)=NaN;
end
end
function s=direction(x)
s="unavailable";if isfinite(x),s="equal_point_error";if x<0,s="primary_lower_point_error";elseif x>0,s="primary_higher_point_error";end,end
end
function x=average(v),x=NaN;if ~isempty(v),x=mean(v);end,end
function x=minimum(v),x=NaN;if ~isempty(v),x=min(v);end,end
function x=maximum(v),x=NaN;if ~isempty(v),x=max(v);end,end
function x=append(x,r),if isempty(x),x=r;else,x(end+1)=r;end,end
function verify_outputs(outputs)
for k=1:numel(outputs)
    assert(isfile(outputs(k).path)&&strcmp(prc_file_hash(outputs(k).path),outputs(k).sha256), ...
        'pbd:SnapshotIntegrity','Completed snapshot output changed: %s',outputs(k).path);
end
end
function write_table_new(T,file)
t=[file '.' char(java.util.UUID.randomUUID()) '.tmp'];writetable(T,t,'FileType','text');commit(t,file);
end
function write_json_new(file,value),write_text_new(file,jsonencode(value,PrettyPrint=true));end
function write_text_new(file,value)
t=[file '.' char(java.util.UUID.randomUUID()) '.tmp'];fid=fopen(t,'w','n','UTF-8');
assert(fid>=0,'pbd:Write','Cannot create %s.',t);c=onCleanup(@()fclose(fid));fprintf(fid,'%s\n',value);clear c;commit(t,file);
end
function commit(t,file)
if isfile(file)
    assert(strcmp(prc_file_hash(file),prc_file_hash(t)),'pbd:Integrity','Existing artifact differs: %s',file);delete(t);
else
    [ok,msg]=movefile(t,file);assert(ok,'pbd:Write','%s',msg);
end
end
