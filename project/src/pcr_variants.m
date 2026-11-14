function V=pcr_variants()
% Matched main groups only. No retrospective frequency or replay tuning.
V=struct('name','main','interval',1,'keep_history',true,'use_offline',true, ...
    'systems',{{'frozen','empty_only','gated_calibration','gated_full'}});
end
