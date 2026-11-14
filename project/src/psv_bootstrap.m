function [pairs,intervals]=psv_bootstrap(R,spec)
% Object-paired percentile bootstrap; model seeds are never independent n.
Q=R(R.model_seed==0,:);conditions=unique(Q.condition,'stable');budgets=unique(Q.train_budget).';processing=["raw","common_clip"];
comparators=["physics_residual_ridge13","steady_qp_nn40","steady_qps_nn48","steady_qps_ridge48","physics_inverse", ...
    "lao_pe_transplant","lao_t_transplant","lao_ta_transplant"];
pr=struct([]);ir=struct([]);group=0;metrics=["mass_mae_g","cx_mae_mm","cz_mae_mm","planar_com_mean_distance_mm"];
for c=1:numel(conditions),for b=budgets,for pp=processing
    ours=Q(Q.condition==conditions(c)&Q.train_budget==b&Q.method=="physics_residual_nn"&Q.postprocessing==pp,:);
    for m=1:numel(comparators)
        other=Q(Q.condition==conditions(c)&Q.train_budget==b&Q.method==comparators(m)&Q.postprocessing==pp,:);if isempty(other),continue,end
        group=group+1;[ids,ia,ib]=intersect(ours.object_id,other.object_id,'stable');A=ours(ia,:);B=other(ib,:);
        ea=errors(A);eb=errors(B);delta=ea-eb;ok=all(isfinite(delta),2);n=sum(ok);
        for j=1:numel(ids)
            r=struct('condition',conditions(c),'train_budget',b,'postprocessing',pp,'reference_method',"physics_residual_nn", ...
                'comparison_method',comparators(m),'object_id',ids(j),'paired_finite',ok(j),'mass_error_difference_g',delta(j,1), ...
                'cx_error_difference_mm',delta(j,2),'cz_error_difference_mm',delta(j,3),'planar_error_difference_mm',delta(j,4));
            if isempty(pr),pr=r;else,pr(end+1)=r;end %#ok<AGROW>
        end
        av=nan(1,4);lo=av;hi=av;
        if n>0
            d=delta(ok,:);av=mean(d,1);stream=RandStream('mt19937ar','Seed',spec.bootstrap_seed+group);
            draw=randi(stream,n,n,spec.bootstrap_replicates);boot=zeros(spec.bootstrap_replicates,4);
            for j=1:4,x=d(:,j);boot(:,j)=mean(x(draw),1).';end
            limits=prctile(boot,[2.5 97.5],1);lo=limits(1,:);hi=limits(2,:);
        end
        for j=1:4
            primary=conditions(c)=="nominal"&&b==600&&comparators(m)=="steady_qp_nn40"&&pp=="common_clip"&&ismember(j,[1 4]);
            r=struct('condition',conditions(c),'train_budget',b,'postprocessing',pp,'reference_method',"physics_residual_nn", ...
                'comparison_method',comparators(m),'metric',metrics(j),'planned_pair_n',numel(ids),'finite_pair_n',n,'missing_pair_n',numel(ids)-n, ...
                'mean_difference',av(j),'ci_lower',lo(j),'ci_upper',hi(j),'bootstrap_replicates',spec.bootstrap_replicates, ...
                'bootstrap_seed',spec.bootstrap_seed+group,'primary_comparison',primary,'interpretation',"negative favors residual NN; unadjusted percentile CI; paired finite objects only");
            if isempty(ir),ir=r;else,ir(end+1)=r;end %#ok<AGROW>
        end
    end
end,end,end
pairs=struct2table(pr);intervals=struct2table(ir);
end
function e=errors(T)
d=1000*([T.pred_mass_kg T.pred_cx_m T.pred_cz_m]-[T.true_mass_kg T.true_cx_m T.true_cz_m]);e=[abs(d),vecnorm(d(:,2:3),2,2)];
end
