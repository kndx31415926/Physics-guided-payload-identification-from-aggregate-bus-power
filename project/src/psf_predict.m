function M=psf_predict(models,F,cfg)
% Models and observation features only; no labels/IDs accepted by this API.
spec=models.spec;ns=numel(spec.network_seeds);M=struct([]);
names={'steady_qps_nn48','steady_qp_nn40','steady_qps_ridge48','physics_residual_ridge13','physics_residual_nn','physics_inverse'};
for b=1:numel(spec.train_sizes)
    for m=1:6
        X=F.steady.x48;offset=zeros(1,3);usable=F.steady.usable;valid=usable;seeds=0;n=1;
        if m==2,X=F.steady.x;end
        if m>=4,X=F.physics.residual;offset=F.physics.base;usable=F.physics.usable;valid=usable&&F.physics.teacher_accepted;end
        if m<=2||m==5,n=ns;seeds=spec.network_seeds;end
        raw=nan(n,3);
        if usable
            for s=1:n
                if m==6,raw(s,:)=F.physics.base;
                else
                    if m==5,learner=models.reference{b,s};kind='nn';else,learner=models.students{b,m,s};kind=learner.kind;end
                    if strcmp(kind,'nn'),p=predict(learner.model,X(:,learner.columns));
                    else,p=psf_ridge('predict',learner.model,X(:,learner.columns));end
                    raw(s,:)=p.*spec.scale+offset;
                end
            end
        end
        bounded=min(max(raw,cfg.ident.bounds(:,1).'),cfg.ident.bounds(:,2).');bounded(~isfinite(raw))=NaN;
        item=struct('name',names{m},'budget',spec.train_sizes(b),'seeds',seeds,'raw',raw,'clipped',bounded,'valid',logical(valid));
        if isempty(M),M=item;else,M(end+1)=item;end %#ok<AGROW>
    end
end
end
