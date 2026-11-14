function status=pgar_data_trial(file,cfg,probe,drift,expected)
% One deterministic full-servo episode, atomically committed to its own file.
% An existing final record is checked and retained, including failed episodes.
if isfile(file),status=pgar_data_inspect_record(file,expected);return,end
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
temporary=[file '.' char(javaMethod('randomUUID','java.util.UUID')) '.tmp'];
save(temporary,'record','-v7.3');
% The client owns the OS data-stage lock. A final record is never overwritten.
assert(~isfile(file),'pgar:TrialRace','Final trial file appeared before commit: %s',file);
[ok,message]=movefile(temporary,file);assert(ok,'pgar:TrialSave','%s',message);
status=pgar_data_inspect_record(file,expected);
end
