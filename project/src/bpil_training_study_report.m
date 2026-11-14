function summary=bpil_training_study_report(outdir,results)
T=results.metrics;s=results.study;methods={'direct','first_moments','physics_residual'};rows=struct([]);
fields={'mass_mae_g','cx_mae_mm','cz_mae_mm'};
for n=s.train_sizes
    for j=1:numel(methods)
        R=T(strcmp(T.method,methods{j})&T.train_n==n,:);
        row=struct('method',methods{j},'train_n',n,'seed_n',height(R));
        for k=1:numel(fields)
            v=R.(fields{k});row.([fields{k} '_seed_mean'])=mean(v);row.([fields{k} '_seed_sd'])=std(v,0);
        end
        if isempty(rows),rows=row;else,rows(end+1)=row;end %#ok<AGROW>
    end
end
summary=struct2table(rows);writetable(summary,fullfile(outdir,'seed_summary.csv'));
f=figure('Visible','off','Position',[100 100 1150 360]);tiledlayout(1,3);colors=lines(3);
for k=1:3
    nexttile;hold on;
    for j=1:numel(methods)
        R=summary(strcmp(summary.method,methods{j}),:);
        errorbar(R.train_n,R.([fields{k} '_seed_mean']),R.([fields{k} '_seed_sd']),'-o','Color',colors(j,:),'LineWidth',1.2);
    end
    y=T.(fields{k})(strcmp(T.method,'physics_inverse'));yline(y,'k--');grid on;
    xlabel('Independent training objects');ylabel(strrep(fields{k},'_',' '));
    if k==1,legend([methods,{'physical inverse'}],'Interpreter','none','Location','best');end
end
sgtitle('Fixed-probe equilibrium: mean and SD over network initialization seeds');
exportgraphics(f,fullfile(outdir,'training_study_errors.png'),'Resolution',160);close(f);
fid=fopen(fullfile(outdir,'SCOPE.txt'),'w');
fprintf(fid,['Fixed nominal robot, ideal equilibrium, one fixed probe_02, no servo trajectories.\n', ...
    'Every row is one object; train/validation/test have separate object seeds.\n', ...
    'Training sizes are nested. Three network seeds share the same data split.\n', ...
    'All predefined architectures reported; test data never select hyperparameters or winner.\n', ...
    'Encoder noise is independent of object labels: q-only has no payload signal here.\n', ...
    'This module does NOT establish servo q-only versus P+q value.\n', ...
    'Physical inverse uses all eight poses and two fixed starts; it differs from the heldout-pose feasibility teacher.\n', ...
    'Residual NN requires physical inverse at deployment and is not equally cheap as direct inference.\n', ...
    'No guarantee that moments or residual architectures beat direct MLP.\n']);fclose(fid);
disp(summary);
end
