function M=bpil_training_study_metrics(truth,prediction)
assert(isequal(size(truth),size(prediction))&&all(isfinite(prediction),'all'),'bpil:Metrics','Invalid predictions');
e=1000*(prediction-truth);a=mean(abs(e),1);r=sqrt(mean(e.^2,1));z=max(abs(e),[],1);
M=struct('n',size(e,1),'mass_mae_g',a(1),'cx_mae_mm',a(2),'cz_mae_mm',a(3), ...
    'mass_rmse_g',r(1),'cx_rmse_mm',r(2),'cz_rmse_mm',r(3), ...
    'mass_max_g',z(1),'cx_max_mm',z(2),'cz_max_mm',z(3));
end
