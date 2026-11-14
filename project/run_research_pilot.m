function results=run_research_pilot(mode,output_name,options)
%RUN_RESEARCH_PILOT Prequential BDCL-style active hefting under finite drift.
% Examples: run_research_pilot('equilibrium'); run_research_pilot('servo');
% This entry point NEVER opens a hardware connection.
cfg=startup_bpil();
if nargin<1,mode='servo';end
if nargin<2,output_name=['pilot_' mode];end
assert(any(strcmp(mode,{'servo','equilibrium'})),'bpil:Mode','Unknown mode');
cfg.experiment.mode=mode;
if strcmp(mode,'equilibrium'),cfg.experiment.blocks=8;cfg.experiment.episodes_per_block=6;end
if nargin>=3
    for key=fieldnames(options).'
        assert(isfield(cfg.experiment,key{1}),'bpil:Option','Unknown experiment option');
        cfg.experiment.(key{1})=options.(key{1});
    end
end
outdir=fullfile(cfg.root,'results',output_name);
if exist(fullfile(outdir,'COMPLETE.txt'),'file')
    error('bpil:ExistingRun','Completed run exists; choose a new output_name.');
end
if ~exist(outdir,'dir'),mkdir(outdir);end
save(fullfile(outdir,'configuration.mat'),'cfg');
snapshot=fullfile(outdir,'source_snapshot');
if ~exist(snapshot,'dir'),mkdir(snapshot);end
copyfile(fullfile(cfg.root,'src'),fullfile(snapshot,'src'));
copyfile(fullfile(cfg.root,'run_research_pilot.m'),snapshot);
copyfile(fullfile(cfg.root,'startup_bpil.m'),snapshot);
copyfile(fullfile(cfg.root,'vendor','UPSTREAM_MANIFEST.csv'),snapshot);
probes=bpil_probe_library(cfg);eta0=struct('coefficients',cfg.legacy.power.coefficients);
cache=fullfile(cfg.root,'results','bootstrap_cache.mat');
cache_key=struct('schema',cfg.schema,'learning',cfg.learning,'bounds',cfg.ident.bounds, ...
    'poses',{arrayfun(@(p)p.poses,probes,'UniformOutput',false)}, ...
    'sensor',cfg.sensor,'power',cfg.legacy.power,'source_hash',local_source_hash(cfg));
reused=false;
if exist(cache,'file')
    B=load(cache);
    if isfield(B,'cache_key')&&isequaln(B.cache_key,cache_key)
        bootstrap=B.bootstrap;validation=B.validation;initial_student=B.initial_student;reused=true;
    end
end
if ~reused
    fprintf('Creating independent offline equilibrium bootstrap and validation.\n');
    bootstrap=bpil_synthetic_data(cfg,probes,eta0,cfg.learning.bootstrap_n,cfg.learning.seed);
    validation=bpil_synthetic_data(cfg,probes,eta0,cfg.learning.validation_n,cfg.learning.seed+1);
    initial_student=bpil_train_student(cfg,bootstrap.X,bootstrap.theta,[],cfg.learning.seed);
    save(cache,'bootstrap','validation','initial_student','cache_key');
end
pred=bpil_student_predict(initial_student,validation.X);
initial_loss=mean(((pred-validation.theta)./cfg.parameter_scale).^2,'all');
fprintf('Bootstrap holdout normalized MSE %.6g; mode=%s.\n',initial_loss,mode);
state=struct('student',initial_student,'bootstrap',bootstrap,'validation',validation, ...
    'replay_X',zeros(0,size(bootstrap.X,2)),'replay_theta',zeros(0,3), ...
    'replay_model_version',zeros(0,1),'calibration_version',0,'update_count',0, ...
    'initial_validation_loss',initial_loss);
eta=eta0;rows=struct([]);anchor_reports=cell(cfg.experiment.blocks,1);
prior_theta=mean(cfg.ident.bounds,2).';episode=0;started=tic;
for block=1:cfg.experiment.blocks
    total_episodes=cfg.experiment.blocks*cfg.experiment.episodes_per_block;
    if strcmp(cfg.experiment.drift_schedule,'gradual')
        drift=bpil_drift(episode+1,total_episodes,cfg.experiment.drift_kind);
    else
        drift=bpil_drift(block,cfg.experiment.blocks,cfg.experiment.drift_kind);
    end
    % Operationally observable empty-arm reference, not a hidden payload label.
    if cfg.experiment.anchor_each_block
        empty=local_payload(cfg,[0 .128 0]);
        [anchor,anchor_truth]=local_observe(cfg,empty,probes(1),drift, ...
            cfg.experiment.seed+1000*block);
        anchor.is_anchor=true;anchor.known_mass_kg=0;
        if local_usable(anchor)
            [eta_candidate,ar]=bpil_calibrate_anchor(cfg,anchor,eta);
            if ar.accepted,eta=eta_candidate;state.calibration_version=state.calibration_version+1;end
        else
            ar=struct('accepted',false,'reason','anchor_observations_unusable');
        end
    else
        anchor=[];anchor_truth=[];
        ar=struct('accepted',false,'reason','anchor_disabled_by_ablation');
    end
    anchor_reports{block}=ar;
    save(fullfile(outdir,sprintf('anchor_%02d.mat',block)), ...
        'anchor','anchor_truth','ar','eta');
    fprintf('Block %d anchor accepted=%d; coefficients %s\n',block,ar.accepted,mat2str(eta.coefficients([1 3 4 5]),4));
    for e=1:cfg.experiment.episodes_per_block
        episode=episode+1;rng(cfg.experiment.seed+episode,'twister');
        if strcmp(cfg.experiment.drift_schedule,'gradual')
            drift=bpil_drift(episode,total_episodes,cfg.experiment.drift_kind);
        end
        % Truth used only by the physical plant and final evaluation.
        theta_true=[.08+.14*rand,.05+.14*rand,-.018+.036*rand];
        payload=local_payload(cfg,theta_true);
        % Independent new objects share a fixed prior; previous object truth
        % or estimate cannot supply an object-specific probing advantage.
        [probe,selection]=bpil_select_probe(cfg,probes,prior_theta,eta);
        [obs,truth]=local_observe(cfg,payload,probe,drift,cfg.experiment.seed+10000+episode);
        usable=local_usable(obs);
        frozen=nan(1,3);calibrated_frozen=nan(1,3);prequential=nan(1,3);
        if usable
            frozen=bpil_student_predict(initial_student,bpil_features(obs,eta0));
            calibrated_frozen=bpil_student_predict(initial_student,bpil_features(obs,eta));
            prequential=bpil_student_predict(state.student,bpil_features(obs,eta));
            frozen_teacher=bpil_teacher(cfg,obs,eta0,frozen);
            teacher=bpil_teacher(cfg,obs,eta,prequential);
        else
            frozen_teacher=bpil_teacher(cfg,obs,eta0,[]);
            teacher=bpil_teacher(cfg,obs,eta,[]);
        end
        update=struct('deployed',false,'trained',false,'reason','observations_unusable');
        if usable
            [state,update]=bpil_ring_update(cfg,state,obs,eta,teacher);
        end
        predictions={frozen,calibrated_frozen,prequential,frozen_teacher.theta,teacher.theta};
        names={'frozen_student','frozen_student_current_calibration','ring_student_preupdate','frozen_teacher','adaptive_teacher'};
        accepted=[usable,usable,usable,frozen_teacher.accepted,teacher.accepted];
        physical_success=truth.success;
        if isfield(truth,'physical_success'),physical_success=truth.physical_success;end
        for m=1:numel(names)
            row=struct('episode',episode,'block',block,'method',names{m}, ...
                'simulation_mode',mode,'probe_id',probe.id,'physical_success',physical_success, ...
                'observation_usable',usable,'overall_success',truth.success, ...
                'accepted',accepted(m),'mass_true_kg',theta_true(1), ...
                'cx_true_m',theta_true(2),'cz_true_m',theta_true(3), ...
                'mass_est_kg',predictions{m}(1),'cx_est_m',predictions{m}(2), ...
                'cz_est_m',predictions{m}(3),'calibration_version',state.calibration_version, ...
                'student_update_deployed',update.deployed);
            if isempty(rows),rows=row;else,rows(end+1)=row;end %#ok<AGROW>
        end
        % Evaluation truth stays in artifacts, never passed to ring_update/features.
        save(fullfile(outdir,sprintf('episode_%03d.mat',episode)), ...
            'obs','truth','eta','selection','teacher','frozen_teacher','update', ...
            'prequential','frozen','calibrated_frozen','theta_true');
        writetable(struct2table(rows),fullfile(outdir,'episodes.csv'));
        save(fullfile(outdir,'checkpoint.mat'),'cfg','state','eta','rows','anchor_reports','episode');
        fprintf('Episode %d/%d: teacher=%d update=%d mass %.1fg -> %.1fg; %.1fs elapsed.\n', ...
            episode,cfg.experiment.blocks*cfg.experiment.episodes_per_block, ...
            teacher.accepted,update.deployed,theta_true(1)*1000,teacher.theta(1)*1000,toc(started));
    end
end
results=struct('cfg',cfg,'rows',struct2table(rows),'anchor_reports',{anchor_reports}, ...
    'state',state,'eta',eta,'elapsed_s',toc(started));
save(fullfile(outdir,'results.mat'),'results','-v7.3');
bpil_summarize(outdir);
fid=fopen(fullfile(outdir,'COMPLETE.txt'),'w');fprintf(fid,'Completed %s\n',char(datetime('now')));fclose(fid);
fprintf('Completed: %s\n',outdir);
end

function p=local_payload(cfg,theta)
p=struct('mass',theta(1),'com',[theta(2) 0 theta(3)], ...
    'dimensions_m',cfg.payload.dimensions_m);
end
function [obs,truth]=local_observe(cfg,payload,probe,drift,seed)
if strcmp(cfg.experiment.mode,'servo')
    [obs,truth]=bpil_simulate_probe(cfg,payload,probe,drift,seed);
else
    [obs,truth]=bpil_equilibrium_observation(cfg,payload,probe,drift,seed);
end
end
function h=local_source_hash(cfg)
names={'bpil_synthetic_data','bpil_features','bpil_train_student','bpil_static_design'};
h=cell(size(names));for k=1:numel(names),h{k}=fileread(fullfile(cfg.root,'src',[names{k} '.m']));end
end
function usable=local_usable(obs)
usable=all(obs.stationary)&&all(isfinite(obs.plateau_q),'all')&&all(isfinite(obs.plateau_P));
end
