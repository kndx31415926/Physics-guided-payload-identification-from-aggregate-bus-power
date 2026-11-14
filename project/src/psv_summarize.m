function S=psv_summarize(R)
S=psf_summarize(R);S.aggregation(:)="one_paired_object_noise_draw_per_condition";
S.physical_failure_n=zeros(height(S),1);S.steady_unusable_n=S.physical_failure_n;S.physics_unusable_n=S.physical_failure_n;
for i=1:height(S)
    q=R.condition==S.condition(i)&R.train_budget==S.train_budget(i)&R.method==S.method(i)&R.model_seed==S.model_seed(i)&R.postprocessing==S.postprocessing(i);
    S.physical_failure_n(i)=sum(~R.physical_success(q));S.steady_unusable_n(i)=sum(~R.steady_usable(q));S.physics_unusable_n(i)=sum(~R.physics_usable(q));
end
end
