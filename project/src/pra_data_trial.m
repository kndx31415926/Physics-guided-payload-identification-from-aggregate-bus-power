function status=pra_data_trial(file,cfg,probe,drift,expected)
%PRA_DATA_TRIAL Atomically save one complete servo episode, failures included.
% Known calibration labels are separate from evaluation-only theta_true.
if isfile(file),status=pgar_data_inspect_record(file,expected);return,end
assert(isequaln(drift,expected.drift),'pra:DriftMismatch','Trial drift differs from the fixed plan.');
record=expected;record.obs=[];record.truth=[];record.error=[];
payload=struct('mass',expected.theta_true(1),'com',[expected.theta_true(2) 0 expected.theta_true(3)], ...
    'dimensions_m',cfg.payload.dimensions_m);
try
    [record.obs,record.truth]=bpil_simulate_probe(cfg,payload,probe,drift,expected.sensor_seed);
catch err
    record.error=struct('identifier',err.identifier,'message',err.message,'stack',err.stack);
end
record.completed_utc=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));
record.complete=true;
% Keep the temporary filename short for Windows snapshot workspaces.
[folder,~,~]=fileparts(file);temporary=fullfile(folder,['t_' char(javaMethod('randomUUID','java.util.UUID')) '.mat']);
save(temporary,'record','-v7.3');
assert(~isfile(file),'pra:TrialRace','Final record appeared before commit: %s',file);
[ok,message]=movefile(temporary,file);assert(ok,'pra:TrialSave','%s',message);
status=pgar_data_inspect_record(file,expected);
end
