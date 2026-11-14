function results=bpil_training_study_confirm(output_name,base_name)
%BPIL_TRAINING_STUDY_CONFIRM Validation-selected budget, then unseen test.
% Reuses the fixed 5000-object training and 600-object validation splits.
% Both direct and first-moment models receive the same candidate budgets.
% No candidate is selected using either v1 test or the new test observations.
if nargin<1,output_name='training_study_confirmatory_v1';end
if nargin<2,base_name='training_study_equilibrium_v1';end
root=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
maxNumCompThreads(1); %#ok<MAXNCT>
base=fullfile(root,'results',base_name);out=fullfile(root,'results',output_name);
assert(isfile(fullfile(base,'COMPLETE.txt')),'bpil:IncompleteBase','Base study must be complete.');
assert(~exist(out,'dir'),'bpil:ExistingRun','Choose a new output directory.');
mkdir(out);mkdir(fullfile(out,'source_snapshot'));
copyfile(fullfile(root,'src'),fullfile(out,'source_snapshot','src'));
diary(fullfile(out,'run.log'));cleanup=onCleanup(@()diary('off')); %#ok<NASGU>
started=tic;B=load(fullfile(base,'study_configuration.mat'));
cfg=B.cfg;s=B.s;probe=B.probe;eta=B.eta;
D=load(fullfile(base,'datasets.mat'),'train','validation');
train=D.train;validation=D.validation;
spec=struct('schema','validation_selected_training_budget_v1', ...
    'methods',{{'direct','first_moments'}},'budgets',[350 1500], ...
    'network_seeds',[731 732 733],'train_n',5000,'validation_n',600, ...
    'new_test_seed',910034,'test_n',1000,'base_run',base, ...
    'selection_rule','Per method: minimum mean validation physical normalized MSE over all three initialization seeds; ties choose smaller budget.', ...
    'loss_definition','Mean over objects and parameters of ((theta_est-theta_true)./[0.25,0.20,0.025]).^2; after identical physical bounding.', ...
    'test_rule','Create new test only after validation budget selection is saved. Evaluate selected budget, all three seeds, no winner selection.');
assert(size(train.theta,1)==spec.train_n&&size(validation.theta,1)==spec.validation_n,'bpil:DatasetSize','Unexpected base split sizes.');
assert(~ismember(spec.new_test_seed,s.data_seeds),'bpil:TestSeed','New test must use a new seed.');
save(fullfile(out,'confirmatory_configuration.mat'),'cfg','s','spec','probe','eta');
fprintf('Confirmation: methods direct/first_moments, budgets 350/1500, three seeds; new test not yet generated.\n');
rows=struct([]);candidates=struct([]);
for j=1:numel(spec.methods)
    method=spec.methods{j};
    for budget=spec.budgets
        for seed=spec.network_seeds
            if budget==350
                A=load(fullfile(base,sprintf('model_%s_n%d_seed%d.mat',method,spec.train_n,seed)), ...
                    'model','pv','fit_s');model=A.model;pv=A.pv;fit_s=A.fit_s;reused=true;
            else
                candidate_config=s;candidate_config.iterations=budget;t=tic;
                model=bpil_training_study_fit(cfg,candidate_config,method,train.X,train.theta,zeros(size(train.theta)),seed);
                fit_s=toc(t);pv=bpil_training_study_predict(model,validation.X,zeros(size(validation.theta)));reused=false;
            end
            v=bpil_training_study_metrics(validation.theta,pv);
            val_loss=mean(((pv-validation.theta)./cfg.parameter_scale).^2,'all');
            c=model.regressor.ConvergenceInfo;
            r=struct('method',method,'train_n',spec.train_n,'budget',budget,'network_seed',seed, ...
                'validation_mse_normalized',val_loss,'validation_mass_mae_g',v.mass_mae_g, ...
                'validation_cx_mae_mm',v.cx_mae_mm,'validation_cz_mae_mm',v.cz_mae_mm, ...
                'fit_s',fit_s,'reused_v1_model',reused,'iterations',c.Iterations, ...
                'at_iteration_limit',c.Iterations>=budget,'training_loss_scaled',c.TrainingLoss, ...
                'gradient',c.Gradient,'convergence_criterion',string(c.ConvergenceCriterion));
            item=struct('method',method,'budget',budget,'seed',seed,'model',model,'pv',pv,'validation_metrics',v);
            if isempty(rows),rows=r;candidates=item;else,rows(end+1)=r;candidates(end+1)=item;end %#ok<AGROW>
            save(fullfile(out,sprintf('candidate_%s_budget%d_seed%d.mat',method,budget,seed)), ...
                'model','pv','v','val_loss','r','-v7.3');
            writetable(struct2table(rows),fullfile(out,'validation_candidates.csv'));
            fprintf('%s budget=%d seed=%d: validation normalized MSE %.8g, MAE %.4fg %.4fmm %.4fmm, iteration limit=%d.\n', ...
                method,budget,seed,val_loss,v.mass_mae_g,v.cx_mae_mm,v.cz_mae_mm,r.at_iteration_limit);
        end
    end
end
V=struct2table(rows);selection=struct([]);scores=struct([]);
for j=1:numel(spec.methods)
    method=spec.methods{j};means=zeros(size(spec.budgets));
    for b=1:numel(spec.budgets)
        R=V(strcmp(V.method,method)&V.budget==spec.budgets(b),:);
        assert(height(R)==numel(spec.network_seeds),'bpil:CandidateSeeds','Incomplete candidate seeds.');
        means(b)=mean(R.validation_mse_normalized);
        r=struct('method',method,'budget',spec.budgets(b),'validation_mse_seed_mean',means(b), ...
            'validation_mse_seed_sd',std(R.validation_mse_normalized), ...
            'mass_mae_seed_mean_g',mean(R.validation_mass_mae_g), ...
            'cx_mae_seed_mean_mm',mean(R.validation_cx_mae_mm),'cz_mae_seed_mean_mm',mean(R.validation_cz_mae_mm));
        if isempty(scores),scores=r;else,scores(end+1)=r;end %#ok<AGROW>
    end
    [best_loss,best]=min(means);
    pick=struct('method',method,'selected_budget',spec.budgets(best),'validation_mse_seed_mean',best_loss);
    if isempty(selection),selection=pick;else,selection(end+1)=pick;end %#ok<AGROW>
end
selection_locked_at=datetime('now');
save(fullfile(out,'LOCKED_SELECTION_BEFORE_TEST.mat'),'selection','selection_locked_at','spec');
writetable(struct2table(scores),fullfile(out,'validation_budget_summary.csv'));
writetable(struct2table(selection),fullfile(out,'selected_budgets.csv'));
fprintf('Validation selection locked before new test generation, %.1fs elapsed.\n',toc(started));disp(struct2table(selection));
test=bpil_training_study_data(cfg,probe,eta,spec.test_n,spec.new_test_seed,'confirm_test');
assert(~any(ismember(test.theta,train.theta,'rows'))&&~any(ismember(test.theta,validation.theta,'rows')), ...
    'bpil:SplitOverlap','New test overlaps train or validation.');
save(fullfile(out,'new_test_dataset.mat'),'test','-v7.3');
observed=struct('P',test.P,'Q',test.Q,'split',test.split);
inverse=bpil_training_study_inverse(cfg,observed,eta,s);
save(fullfile(out,'new_test_inverse.mat'),'inverse','-v7.3');
M=bpil_training_study_metrics(test.theta,inverse.theta);
testrows=local_row('physics_inverse',0,0,M);predictions=local_predictions(test,inverse.theta,'physics_inverse',0,0);
for j=1:numel(selection)
    method=selection(j).method;budget=selection(j).selected_budget;
    for seed=spec.network_seeds
        ix=find(strcmp({candidates.method},method)&[candidates.budget]==budget&[candidates.seed]==seed);
        assert(isscalar(ix),'bpil:CandidateLookup','Missing or duplicated candidate.');
        model=candidates(ix).model;pt=bpil_training_study_predict(model,test.X,zeros(size(test.theta)));
        M=bpil_training_study_metrics(test.theta,pt);
        testrows(end+1)=local_row(method,budget,seed,M); %#ok<AGROW>
        predictions=[predictions;local_predictions(test,pt,method,budget,seed)]; %#ok<AGROW>
        save(fullfile(out,sprintf('selected_test_%s_budget%d_seed%d.mat',method,budget,seed)),'pt','M');
        fprintf('New test %s budget=%d seed=%d: %.4fg %.4fmm %.4fmm.\n',method,budget,seed,M.mass_mae_g,M.cx_mae_mm,M.cz_mae_mm);
    end
end
T=struct2table(testrows);writetable(T,fullfile(out,'test_metrics.csv'));
writetable(predictions,fullfile(out,'test_predictions.csv'));
summary=struct([]);fields={'mass_mae_g','cx_mae_mm','cz_mae_mm'};
for j=1:numel(selection)
    R=T(strcmp(T.method,selection(j).method),:);r=struct('method',selection(j).method,'selected_budget',selection(j).selected_budget,'seed_n',height(R));
    for k=1:numel(fields)
        r.([fields{k} '_seed_mean'])=mean(R.(fields{k}));r.([fields{k} '_seed_sd'])=std(R.(fields{k}));
    end
    if isempty(summary),summary=r;else,summary(end+1)=r;end %#ok<AGROW>
end
summary=struct2table(summary);writetable(summary,fullfile(out,'test_seed_summary.csv'));
results=struct('spec',spec,'selection',selection,'validation',V,'test',T,'summary',summary,'elapsed_s',toc(started));
save(fullfile(out,'results.mat'),'results','-v7.3');
fid=fopen(fullfile(out,'SCOPE.txt'),'w');
fprintf(fid,['v1 remains a separate fixed-budget exploratory comparison.\n', ...
    'This confirmation was motivated by observing iteration limits; both architectures are included.\n', ...
    '350/1500 budget selected per architecture using mean validation normalized physical MSE over three seeds.\n', ...
    'All three seeds of the chosen budget are tested; no best-seed selection.\n', ...
    'New test seed 910034 is generated only after selection is saved.\n', ...
    'Same nominal fixed-probe equilibrium scope; q has only independent sensor noise.\n', ...
    'An iteration-limit termination does not establish convergence or globally optimal architecture/training.\n', ...
    'Residual NN is not retuned in this confirmation. No servo, drift, or hardware claims.\n']);fclose(fid);
fid=fopen(fullfile(out,'COMPLETE.txt'),'w');fprintf(fid,'Completed %s\n',char(datetime('now')));fclose(fid);
disp(summary);fprintf('Confirmation complete: %s, %.1fs.\n',out,toc(started));
end

function r=local_row(method,budget,seed,m)
r=struct('method',method,'iteration_budget',budget,'network_seed',seed,'test_n',m.n, ...
    'mass_mae_g',m.mass_mae_g,'cx_mae_mm',m.cx_mae_mm,'cz_mae_mm',m.cz_mae_mm, ...
    'mass_rmse_g',m.mass_rmse_g,'cx_rmse_mm',m.cx_rmse_mm,'cz_rmse_mm',m.cz_rmse_mm, ...
    'mass_max_g',m.mass_max_g,'cx_max_mm',m.cx_max_mm,'cz_max_mm',m.cz_max_mm);
end

function T=local_predictions(D,p,method,budget,seed)
N=size(p,1);T=table(string(D.object_id),repmat(string(method),N,1),repmat(budget,N,1),repmat(seed,N,1), ...
    D.theta(:,1),D.theta(:,2),D.theta(:,3),p(:,1),p(:,2),p(:,3), ...
    'VariableNames',{'object_id','method','iteration_budget','network_seed','mass_true_kg','cx_true_m','cz_true_m','mass_est_kg','cx_est_m','cz_est_m'});
end
