function status=psv_data_trial(file,cfg,probe,condition,expected)
% Labels are used here solely to construct a physical simulated payload.
if isfile(file),status=pgar_data_inspect_record(file,expected);return,end
record=expected;record.obs=[];record.truth=[];record.error=[];
payload=struct('mass',expected.theta_true(1),'com',[expected.theta_true(2) 0 expected.theta_true(3)],'dimensions_m',cfg.payload.dimensions_m);
try
    [record.obs,record.truth]=psv_simulate_probe(cfg,payload,probe,condition,expected.sensor_seed,expected.communication);
catch err,record.error=struct('identifier',err.identifier,'message',err.message,'stack',err.stack);end
record.completed_utc=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));record.complete=true;
temporary=fullfile(fileparts(file),['t_' char(javaMethod('randomUUID','java.util.UUID')) '.mat']);save(temporary,'record','-v7.3');
assert(~isfile(file),'psv:TrialRace','Record appeared before commit.');[ok,message]=movefile(temporary,file);assert(ok,'psv:Save','%s',message);
status=pgar_data_inspect_record(file,expected);
end
