function out=pcr_predict(state,obs)
% Malformed saved observations remain explicit missing predictions.
try,out=pcr_online_predict(state,obs);
catch err
    names={'frozen','empty_only','gated_calibration','gated_full'};
    one=struct('name','','raw',nan(1,3),'clipped',nan(1,3),'candidate_theta',nan(1,3), ...
        'theta',nan(1,3),'accepted',false,'available',false,'bounds_hit',false, ...
        'seed_raw',nan(0,3),'seed_clipped',nan(0,3),'teacher',[],'reasons',{{['prediction_exception:' err.identifier]}});
    methods=repmat(one,1,4);for i=1:4,methods(i).name=names{i};end;out=struct('methods',methods);
end
end
