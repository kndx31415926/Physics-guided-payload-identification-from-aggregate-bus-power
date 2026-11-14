function manifest=generate_servo_study(name,workers)
% Independent objects, identical sensor traces for all signal ablations.
% No wear. Runtime measurements are kept separate from evaluation truth.
if nargin<1,name='servo_signal_study_v1';end
if nargin<2,workers=8;end
cfg=startup_bpil();outdir=fullfile(cfg.root,'results',name);
assert(~exist(outdir,'dir'),'bpil:ExistingRun','Use a fresh study directory');
mkdir(outdir);mkdir(fullfile(outdir,'trials'));snap=fullfile(outdir,'source_snapshot');mkdir(snap);
copyfile(fullfile(cfg.root,'src'),fullfile(snap,'src'));
copyfile(fullfile(cfg.root,'generate_servo_study.m'),snap);
copyfile(fullfile(cfg.root,'startup_bpil.m'),snap);
copyfile(fullfile(cfg.root,'vendor','UPSTREAM_MANIFEST.csv'),snap);
counts=[72 24 24];split_names={'train','validation','test'};
theta=[];split={};
for s=1:3
    rng(44100+s,'twister');U=lhsdesign(counts(s),3,'criterion','maximin','iterations',10);
    theta=[theta;[.08 .05 -.018]+U.*[.14 .14 .036]]; %#ok<AGROW>
    split=[split;repmat(split_names(s),counts(s),1)]; %#ok<AGROW>
end
objects=table((1:size(theta,1)).',string(split),theta(:,1),theta(:,2),theta(:,3), ...
    'VariableNames',{'object_id','split','mass_kg','cx_m','cz_m'});
writetable(objects,fullfile(outdir,'objects.csv'));
probes=bpil_probe_library(cfg);drift=bpil_drift(1,1,'common');
eta=struct('coefficients',cfg.legacy.power.coefficients);
[selected,selection]=bpil_select_probe(cfg,probes,mean(cfg.ident.bounds,2).',eta);
assert(strcmp(selected.id,probes(2).id),'bpil:Probe','Study prespecified probe02 selection');
trial_object=[(1:height(objects)).';find(objects.split=="test")];
trial_probe=[2*ones(height(objects),1);ones(counts(3),1)];
manifest=table((1:numel(trial_object)).',trial_object,trial_probe, ...
    'VariableNames',{'trial_id','object_id','probe_index'});
manifest.split=objects.split(trial_object);
writetable(manifest,fullfile(outdir,'manifest.csv'));
save(fullfile(outdir,'configuration.mat'),'cfg','objects','manifest','probes','drift','selection');
pool=gcp('nocreate');if ~isempty(pool),delete(pool);end
cluster=parcluster('Processes');workers=min(workers,cluster.NumWorkers);
pool=parpool(cluster,workers);cleanup=onCleanup(@()delete(pool)); %#ok<NASGU>
spmd
    maxNumCompThreads(1);
    addpath(cfg.root,fullfile(cfg.root,'src'),fullfile(cfg.root,'vendor','bdcl_v29'));
end
queue=parallel.pool.DataQueue;afterEach(queue,@(v)fprintf('%s\n',v));
started=tic;fprintf('Starting %d full servo trials on %d workers.\n',height(manifest),workers);
parfor i=1:height(manifest)
    oid=trial_object(i);pr=trial_probe(i);th=theta(oid,:);
    payload=struct('mass',th(1),'com',[th(2) 0 th(3)],'dimensions_m',cfg.payload.dimensions_m);
    record=struct('trial_id',i,'object_id',oid,'split',split{oid}, ...
        'probe_id',probes(pr).id,'theta_true',th,'sensor_seed',551000+oid, ...
        'obs',[],'truth',[],'error',[]);
    try
        [record.obs,record.truth]=bpil_simulate_probe(cfg,payload,probes(pr),drift,record.sensor_seed);
        message=sprintf('Trial %d/%d object %d %s %s: physical=%d usable=%d', ...
            i,height(manifest),oid,split{oid},probes(pr).id,record.truth.physical_success, ...
            all(record.obs.stationary));
    catch ME
        record.error=struct('identifier',ME.identifier,'message',ME.message);
        message=sprintf('Trial %d/%d ERROR %s',i,height(manifest),ME.message);
    end
    save_record(fullfile(outdir,'trials',sprintf('trial_%03d.mat',i)),record);
    send(queue,message);
end
elapsed_s=toc(started);save(fullfile(outdir,'generation.mat'),'elapsed_s');
fid=fopen(fullfile(outdir,'DATA_COMPLETE.txt'),'w');
fprintf(fid,'All %d trial records saved; failed trials retained. %.3f seconds.\n',height(manifest),elapsed_s);fclose(fid);
fprintf('DATA COMPLETE %s in %.1fs\n',outdir,elapsed_s);
end

function save_record(path,record)
save(path,'record');
end
