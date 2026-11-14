function results=run_feasibility(output_name,run_servo)
% Fixed-robot feasibility: bus power + encoders, mass and planar COM.
% No wear, online adaptation, or hardware connection in this experiment.
if nargin<1,output_name='feasibility_nominal_v1';end
if nargin<2,run_servo=true;end
cfg=startup_bpil();outdir=fullfile(cfg.root,'results',output_name);
assert(~exist(outdir,'dir'),'bpil:ExistingRun','Choose a fresh output directory');
mkdir(outdir);snap=fullfile(outdir,'source_snapshot');mkdir(snap);
copyfile(fullfile(cfg.root,'src'),fullfile(snap,'src'));
copyfile(fullfile(cfg.root,'run_feasibility.m'),snap);
copyfile(fullfile(cfg.root,'startup_bpil.m'),snap);
copyfile(fullfile(cfg.root,'vendor','UPSTREAM_MANIFEST.csv'),snap);
eta=struct('coefficients',cfg.legacy.power.coefficients);
drift=bpil_drift(1,1,'common');probes=bpil_probe_library(cfg);
[probe,selection]=bpil_select_probe(cfg,probes,mean(cfg.ident.bounds,2).',eta);
fprintf('Fixed nominal robot. Selected %s using fixed prior only.\n',probe.id);
bootstrap=bpil_synthetic_data(cfg,probes,eta,cfg.learning.bootstrap_n,cfg.learning.seed);
validation=bpil_synthetic_data(cfg,probes,eta,cfg.learning.validation_n,cfg.learning.seed+1);
student=bpil_train_student(cfg,bootstrap.X,bootstrap.theta,[],cfg.learning.seed);
save(fullfile(outdir,'configuration.mat'),'cfg','eta','drift','probe','selection');
save(fullfile(outdir,'offline_student.mat'),'student','bootstrap','validation','-v7.3');
% Predeclared contrasts: equal COM/different mass; equal mass/different COM.
cases=[.08 .128 0;.15 .128 0;.22 .128 0; ...
       .15 .06 0;.15 .10 0;.15 .18 0; ...
       .15 .128 -.018;.15 .128 .018; ...
       .08 .06 -.018;.22 .18 .018;.12 .16 -.012;.19 .08 .012];
rng(731029,'twister');
random_cases=[.08+.14*rand(120,1),.05+.14*rand(120,1),-.018+.036*rand(120,1)];
rows=struct([]);started=tic;
modes={'equilibrium'};if run_servo,modes{end+1}='servo';end
for k=1:numel(modes)
    mode=modes{k};theta_cases=cases;
    if strcmp(mode,'equilibrium'),theta_cases=[cases;random_cases];end
    for i=1:size(theta_cases,1)
        theta_true=theta_cases(i,:);
        payload=struct('mass',theta_true(1),'com',[theta_true(2) 0 theta_true(3)], ...
            'dimensions_m',cfg.payload.dimensions_m);
        if strcmp(mode,'servo')
            [obs,truth]=bpil_simulate_probe(cfg,payload,probe,drift,731029+i);
        else
            [obs,truth]=bpil_equilibrium_observation(cfg,payload,probe,drift,731029+i);
        end
        usable=all(obs.stationary)&&all(isfinite(obs.plateau_q),'all')&&all(isfinite(obs.plateau_P));
        prediction=nan(1,3);
        if usable,prediction=bpil_student_predict(student,bpil_features(obs,eta));end
        initial=[];if usable,initial=prediction;end
        teacher=bpil_teacher(cfg,obs,eta,initial);
        physical=truth.success;if isfield(truth,'physical_success'),physical=truth.physical_success;end
        estimates={prediction,teacher.theta};names={'offline_trained_network','physics_inverse'};
        accept=[usable,teacher.accepted];
        for j=1:2
            r=struct('episode',i,'block',1,'method',names{j},'simulation_mode',mode, ...
                'probe_id',probe.id,'physical_success',physical, ...
                'observation_usable',usable,'overall_success',truth.success,'accepted',accept(j), ...
                'mass_true_kg',theta_true(1),'cx_true_m',theta_true(2),'cz_true_m',theta_true(3), ...
                'mass_est_kg',estimates{j}(1),'cx_est_m',estimates{j}(2),'cz_est_m',estimates{j}(3));
            if isempty(rows),rows=r;else,rows(end+1)=r;end %#ok<AGROW>
        end
        save(fullfile(outdir,sprintf('%s_%03d.mat',mode,i)), ...
            'obs','truth','theta_true','prediction','teacher');
        writetable(struct2table(rows),fullfile(outdir,'episodes.csv'));
        if strcmp(mode,'servo')||mod(i,30)==0
            fprintf('%s %d/%d: physical=%d usable=%d teacher=%d | m %.1f -> NN %.1f, inverse %.1f g; elapsed %.1fs.\n', ...
                mode,i,size(theta_cases,1),physical,usable,teacher.accepted, ...
                theta_true(1)*1000,prediction(1)*1000,teacher.theta(1)*1000,toc(started));
        end
    end
    sub=fullfile(outdir,mode);mkdir(sub);
    T=struct2table(rows);writetable(T(strcmp(T.simulation_mode,mode),:),fullfile(sub,'episodes.csv'));
    bpil_summarize(sub);
end
results=struct('cfg',cfg,'rows',struct2table(rows),'cases',cases, ...
    'random_cases',random_cases,'elapsed_s',toc(started));
save(fullfile(outdir,'results.mat'),'results','-v7.3');
local_plot(outdir,results.rows);
fid=fopen(fullfile(outdir,'COMPLETE.txt'),'w');fprintf(fid,'Completed %s\n',char(datetime('now')));fclose(fid);
fprintf('Fixed-robot feasibility complete: %s\n',outdir);
end

function local_plot(outdir,T)
f=figure('Visible','off','Position',[100 100 1200 650]);tiledlayout(2,3,'TileSpacing','compact');
fields={'mass','cx','cz'};units={'Mass (g)','COM x (mm)','COM z (mm)'};
modes=unique(T.simulation_mode,'stable');names=unique(T.method,'stable');
for k=1:numel(modes)
    for p=1:3
        nexttile;hold on;
        for j=1:numel(names)
            M=strcmp(T.simulation_mode,modes{k})&strcmp(T.method,names{j});
            suffix='_m';if p==1,suffix='_kg';end
            x=1000*T.([fields{p} '_true' suffix])(M);y=1000*T.([fields{p} '_est' suffix])(M);
            scatter(x,y,22,'filled','MarkerFaceAlpha',.65);
        end
        lo=min(x);hi=max(x);plot([lo hi],[lo hi],'k--','HandleVisibility','off');
        xlabel(['True ' units{p}]);ylabel(['Estimated ' units{p}]);grid on;
        title(modes{k},'Interpreter','none');
        if p==1,legend(names,'Interpreter','none','Location','best','FontSize',8);end
    end
end
sgtitle('Fixed robot: independent objects; no online update; planar COM only');
exportgraphics(f,fullfile(outdir,'feasibility_scatter.png'),'Resolution',160);close(f);
end
