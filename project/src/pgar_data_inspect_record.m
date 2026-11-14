function status=pgar_data_inspect_record(file,expected)
% Fail closed on corrupt/mismatched final files; never overwrite them.
saved=load(file,'record');
assert(isfield(saved,'record')&&isstruct(saved.record)&&isscalar(saved.record), ...
    'pgar:RecordSchema','Invalid record file: %s',file);
r=saved.record;
assert(all(isfield(r,[fieldnames(expected);{'obs';'truth';'error';'complete';'completed_utc'}]))&&isequal(r.complete,true), ...
    'pgar:RecordSchema','Incomplete committed record: %s',file);
fields=fieldnames(expected);
for k=1:numel(fields)
    name=fields{k};assert(isequaln(r.(name),expected.(name)), ...
        'pgar:RecordMismatch','Record metadata %s does not match the fixed plan: %s',name,file);
end
exception=~isempty(r.error);
physical=~exception&&isstruct(r.truth)&&isfield(r.truth,'physical_success')&&isequal(r.truth.physical_success,true);
usable=~exception&&isstruct(r.obs)&&all(isfield(r.obs,{'plateau_q','plateau_P','stationary'}));
if usable
    usable=isequal(size(r.obs.plateau_q),[8 4])&&numel(r.obs.plateau_P)==8&& ...
        numel(r.obs.stationary)==8&&all(isfinite(r.obs.plateau_q),'all')&& ...
        all(isfinite(r.obs.plateau_P),'all')&&all(r.obs.stationary==1,'all');
end
status=struct('failed',exception||~physical||~usable,'physical_failed',~physical, ...
    'unusable',~usable,'exception',exception);
end
