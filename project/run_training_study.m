function results=run_training_study(output_name,options)
%RUN_TRAINING_STUDY Fixed-robot equilibrium architecture/sample-size study.
% Does not launch hardware, servo simulation, drift, or online adaptation.
% Examples: run_training_study('training_study_equilibrium_v1');
% Run configurations are fixed before test scoring; no test-driven selection.
if nargin<1,output_name='training_study_equilibrium_v1';end
if nargin<2,options=struct();end
root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
cfg=bpil_config(root);s=bpil_training_study_config(options);
maxNumCompThreads(1); %#ok<MAXNCT>
outdir=fullfile(root,'results',output_name);
assert(~exist(outdir,'dir'),'bpil:ExistingRun','Choose a new output directory.');
mkdir(outdir);snap=fullfile(outdir,'source_snapshot');mkdir(snap);
copyfile(fullfile(root,'src'),fullfile(snap,'src'));
copyfile(fullfile(root,'run_training_study.m'),snap);
copyfile(fullfile(root,'vendor','UPSTREAM_MANIFEST.csv'),snap);
diary(fullfile(outdir,'run.log'));cleanup=onCleanup(@()diary('off')); %#ok<NASGU>
started=tic;probes=bpil_probe_library(cfg);probe=probes(2);
eta=struct('coefficients',cfg.legacy.power.coefficients);
save(fullfile(outdir,'study_configuration.mat'),'cfg','s','probe','eta');
fprintf('Fixed probe_02 equilibrium study; %d maximum training objects, %d validation, %d test.\n',max(s.train_sizes),s.validation_n,s.test_n);
train=bpil_training_study_data(cfg,probe,eta,max(s.train_sizes),s.data_seeds(1),'train');
validation=bpil_training_study_data(cfg,probe,eta,s.validation_n,s.data_seeds(2),'validation');
test=bpil_training_study_data(cfg,probe,eta,s.test_n,s.data_seeds(3),'test');
assert(~any(ismember(train.theta,validation.theta,'rows'))&& ...
    ~any(ismember(train.theta,test.theta,'rows'))&& ...
    ~any(ismember(validation.theta,test.theta,'rows')),'bpil:SplitOverlap','Object parameters overlap across splits.');
save(fullfile(outdir,'datasets.mat'),'train','validation','test','-v7.3');
fprintf('Independent object datasets saved; %.1fs elapsed.\n',toc(started));
% Physical baselines use measured P/q only; never initialize with object truth.
inverse_train=bpil_training_study_inverse(cfg,local_measurements(train),eta,s);
inverse_validation=bpil_training_study_inverse(cfg,local_measurements(validation),eta,s);
inverse_test=bpil_training_study_inverse(cfg,local_measurements(test),eta,s);
save(fullfile(outdir,'inverse_cache.mat'),'inverse_train','inverse_validation','inverse_test','-v7.3');
fprintf('All fixed-budget inverse predictions cached; %.1fs elapsed.\n',toc(started));
methods={'direct','first_moments','physics_residual'};
rows=struct([]);predictions=table();
baseline=bpil_training_study_metrics(test.theta,inverse_test.theta);
base=local_row('physics_inverse',0,0,baseline,bpil_training_study_metrics(validation.theta,inverse_validation.theta),inverse_test.elapsed_s,NaN);
base.inverse_converged_n=sum(inverse_test.converged);rows=base;
predictions=local_predictions(test,inverse_test.theta,'physics_inverse',0,0);
for n=s.train_sizes
    for seed=s.network_seeds
        for j=1:numel(methods)
            method=methods{j};rng(seed,'twister');fit_started=tic;
            model=bpil_training_study_fit(cfg,s,method,train.X(1:n,:),train.theta(1:n,:),inverse_train.theta(1:n,:),seed);
            fit_s=toc(fit_started);
            pv=bpil_training_study_predict(model,validation.X,inverse_validation.theta);
            % Validation is logged; all predefined models are retained and tested.
            validation_metrics=bpil_training_study_metrics(validation.theta,pv);
            predict_started=tic;pt=bpil_training_study_predict(model,test.X,inverse_test.theta);
            predict_s=toc(predict_started);
            metrics=bpil_training_study_metrics(test.theta,pt);
            row=local_row(method,n,seed,metrics,validation_metrics,fit_s,predict_s);
            row.inverse_converged_n=NaN;rows(end+1)=row; %#ok<AGROW>
            predictions=[predictions;local_predictions(test,pt,method,n,seed)]; %#ok<AGROW>
            save(fullfile(outdir,sprintf('model_%s_n%d_seed%d.mat',method,n,seed)), ...
                'model','pv','pt','metrics','validation_metrics','fit_s','predict_s','-v7.3');
            writetable(struct2table(rows),fullfile(outdir,'metrics.csv'));
            writetable(predictions,fullfile(outdir,'test_predictions.csv'));
            fprintf('%s n=%d seed=%d: test MAE %.4fg %.4fmm %.4fmm; fit %.1fs; elapsed %.1fs.\n', ...
                method,n,seed,metrics.mass_mae_g,metrics.cx_mae_mm,metrics.cz_mae_mm,fit_s,toc(started));
        end
    end
end
results=struct('study',s,'cfg',cfg,'metrics',struct2table(rows),'elapsed_s',toc(started));
save(fullfile(outdir,'results.mat'),'results','-v7.3');
bpil_training_study_report(outdir,results);
fid=fopen(fullfile(outdir,'COMPLETE.txt'),'w');fprintf(fid,'Completed %s\n',char(datetime('now')));fclose(fid);
fprintf('Study complete: %s, %.1f seconds.\n',outdir,toc(started));
end

function row=local_row(method,n,seed,m,v,fit_s,predict_s)
row=struct('method',method,'train_n',n,'network_seed',seed, ...
    'test_n',m.n,'mass_mae_g',m.mass_mae_g,'cx_mae_mm',m.cx_mae_mm,'cz_mae_mm',m.cz_mae_mm, ...
    'mass_rmse_g',m.mass_rmse_g,'cx_rmse_mm',m.cx_rmse_mm,'cz_rmse_mm',m.cz_rmse_mm, ...
    'mass_max_g',m.mass_max_g,'cx_max_mm',m.cx_max_mm,'cz_max_mm',m.cz_max_mm, ...
    'validation_mass_mae_g',v.mass_mae_g,'validation_cx_mae_mm',v.cx_mae_mm,'validation_cz_mae_mm',v.cz_mae_mm, ...
    'fit_or_inverse_s',fit_s,'network_prediction_s',predict_s,'inverse_converged_n',NaN);
end

function T=local_predictions(D,p,method,n,seed)
N=size(p,1);T=table(string(D.object_id),repmat(string(method),N,1),repmat(n,N,1),repmat(seed,N,1), ...
    D.theta(:,1),D.theta(:,2),D.theta(:,3),p(:,1),p(:,2),p(:,3), ...
    'VariableNames',{'object_id','method','train_n','network_seed','mass_true_kg','cx_true_m','cz_true_m','mass_est_kg','cx_est_m','cz_est_m'});
end

function M=local_measurements(D)
% Deliberately omit true payload parameters and object identifiers.
M=struct('P',D.P,'Q',D.Q,'split',D.split);
end
