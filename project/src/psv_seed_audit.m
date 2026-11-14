function audit=psv_seed_audit(root,plan)
% Read only immediate result manifests/specs/objects, not old trajectories.
dirs=dir(fullfile(root,'results'));dirs=dirs([dirs.isdir]);paths=strings(0,1);hashes=paths;
oldSensor=[];oldCommunication=[];oldObjectSeeds=[];oldTheta=zeros(0,3);
for d=1:numel(dirs)
    name=dirs(d).name;if startsWith(name,'.')||(startsWith(name,'psv_')&&contains(name,'smoke')),continue,end
    folder=fullfile(dirs(d).folder,name);
    if isfield(plan.spec,'inherit_unstarted_plan_dir')&&strcmpi(folder,plan.spec.inherit_unstarted_plan_dir)
        assert(~isfile(fullfile(folder,'DATA_COMPLETE.json'))&&~isfile(fullfile(folder,'COMPLETE.json'))&& ...
            isempty(dir(fullfile(folder,'trials','trial_*.mat')))&&isempty(dir(fullfile(folder,'evaluation_checkpoints','case_*.mat'))), ...
            'psv:ReservationUsed','A reservation with generated/evaluated cases cannot be inherited.');
        old=load(fullfile(folder,'data_plan.mat'));assert(isequaln(old.objects,plan.objects)&&isequaln(old.manifest,plan.manifest)&&isequaln(old.conditions,plan.conditions), ...
            'psv:ReservationMismatch','Inherited unused plan changed objects, noise or conditions.');
        for part={'data_plan.mat','spec.json','LOCKED_BEFORE_GENERATION.mat'}
            file=fullfile(folder,part{1});paths(end+1)=string(file);hashes(end+1)=string(prc_file_hash(file)); %#ok<AGROW>
        end
        continue
    end
    file=fullfile(folder,'manifest.csv');
    if isfile(file)
        T=readtable(file,'TextType','string','Delimiter',',','VariableNamingRule','preserve');
        for key={'sensor_seed'},if ismember(key{1},T.Properties.VariableNames),oldSensor=[oldSensor;double(T.(key{1})(:))];end,end %#ok<AGROW>
        for key={'communication_seed','realized_seed','jitter_seed'},if ismember(key{1},T.Properties.VariableNames),oldCommunication=[oldCommunication;double(T.(key{1})(:))];end,end %#ok<AGROW>
        paths(end+1)=string(file);hashes(end+1)=string(prc_file_hash(file)); %#ok<AGROW>
    end
    file=fullfile(folder,'objects.csv');
    if isfile(file)
        T=readtable(file,'TextType','string','Delimiter',',','VariableNamingRule','preserve');
        if all(ismember({'mass_kg','cx_m','cz_m'},T.Properties.VariableNames)),oldTheta=[oldTheta;T.mass_kg T.cx_m T.cz_m];end %#ok<AGROW>
        paths(end+1)=string(file);hashes(end+1)=string(prc_file_hash(file)); %#ok<AGROW>
    end
    file=fullfile(folder,'spec.json');
    if isfile(file)
        J=jsondecode(fileread(file));oldObjectSeeds=[oldObjectSeeds;seed_fields(J)]; %#ok<AGROW>
        paths(end+1)=string(file);hashes(end+1)=string(prc_file_hash(file)); %#ok<AGROW>
    end
end
assert(~ismember(plan.spec.object_seed,oldObjectSeeds),'psv:SeedReuse','Object seed appeared in an earlier specification.');
assert(isempty(intersect(plan.manifest.sensor_seed,oldSensor)),'psv:SeedReuse','Sensor seed overlap.');
assert(isempty(intersect(plan.manifest.communication_seed,oldCommunication)),'psv:SeedReuse','Communication seed overlap.');
theta=[plan.objects.mass_kg plan.objects.cx_m plan.objects.cz_m];duplicates=0;
for i=1:size(theta,1),duplicates=duplicates+any(all(abs(oldTheta-theta(i,:))<1e-12,2));end
assert(duplicates==0,'psv:ObjectReuse','An exactly matching old object was found.');paths=paths(:);hashes=hashes(:);
audit=struct('passed',true,'scope','Immediate results spec.json/manifest.csv/objects.csv, excluding PSV engineering smoke runs.', ...
    'inherited_unstarted_reservation',string(plan.spec.inherit_unstarted_plan_dir), ...
    'old_sensor_seed_count',numel(unique(oldSensor)),'old_communication_seed_count',numel(unique(oldCommunication)), ...
    'old_parameter_tuple_count',size(oldTheta,1),'duplicate_parameter_tuples',duplicates, ...
    'files',table(paths,hashes,'VariableNames',{'input_path','sha256'}));
end
function x=seed_fields(s)
x=[];if ~isstruct(s),return,end
f=fieldnames(s);for k=1:numel(f),v=s.(f{k});
    if isnumeric(v)&&contains(lower(f{k}),'seed'),x=[x;double(v(:))]; %#ok<AGROW>
    elseif isstruct(v)&&isscalar(v),x=[x;seed_fields(v)];end %#ok<AGROW>
end
end
