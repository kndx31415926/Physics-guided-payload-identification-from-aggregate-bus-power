function S=payload_pnn_subset(D,splits)
% Recreate the original dataset struct for selected split rows, in row order.
ix=ismember(string(D.split),string(splits));S=D;
fields={'X13','Xaug','base','physics8','theta','usable','accepted', ...
    'physics8accepted','physics8usable','physical_success','feature_usable', ...
    'object_id','trial_id','split','condition','record_sha256','feature_sha256'};
for k=1:numel(fields),S.(fields{k})=D.(fields{k})(ix,:);end
S.failed_n=sum(~S.usable);S.planned_n=sum(ix);
end
