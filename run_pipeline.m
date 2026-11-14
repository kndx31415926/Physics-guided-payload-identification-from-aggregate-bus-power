function report=run_pipeline(action,outputDirectory)
%RUN_PIPELINE Analyze supplied simulation data or generate one example probe.
%   run_pipeline                     : summaries and saved-model predictions
%   run_pipeline('summary')          : descriptive errors and coverage
%   run_pipeline('predictions')      : nine-method inference on 8000 trials
%   run_pipeline('evaluation')       : inference and paired-object bootstrap
%   run_pipeline('online_statistics'): paired-stream adaptation statistics
%   run_pipeline('training_plan')    : feature-based training configuration
%   run_pipeline('simulate_plan')    : configuration for one training probe
%   run_pipeline('simulate')         : generate that probe and its features
%   run_pipeline('hardware_dry_run') : inspect the robot interface configuration
% Outputs are written to a new directory under outputs/ by default.
if nargin<1||isempty(action),action='all';end
if nargin<2,outputDirectory='';end
root=fileparts(mfilename('fullpath'));action=char(string(action));
allowed={'all','summary','predictions','evaluation','online_statistics', ...
    'training_plan','simulate_plan','simulate','hardware_dry_run'};
assert(ismember(action,allowed),'payload:Action','Unknown action. See help run_pipeline.');
oldpath=path;cleanup=onCleanup(@()path(oldpath)); %#ok<NASGU>
addpath(fullfile(root,'analysis'));
if isempty(outputDirectory)
    stamp=char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'));
    outputDirectory=fullfile(root,'outputs',[action '_' stamp]);
end
outputDirectory=payload_pnn_output_dir(root,outputDirectory,'pipeline');
report=struct('schema','payload_pipeline_v1','action',action, ...
    'matlab_version',version,'root',root,'output_directory',outputDirectory, ...
    'hardware_opened',false,'models_trained',0,'new_trajectories',0);
fprintf('Pipeline outputs: %s\n',outputDirectory);
if ismember(action,{'all','summary'})
    report.summary=payload_recompute_results(root,fullfile(outputDirectory,'summary'));
end
if ismember(action,{'all','predictions'})
    report.predictions=payload_pnn_predictions(root,fullfile(outputDirectory,'predictions'));
end
if strcmp(action,'evaluation')
    report.evaluation=payload_pnn_evaluate(root,fullfile(outputDirectory,'evaluation'));
end
if strcmp(action,'online_statistics')
    report.online_statistics=payload_online_statistics(root,fullfile(outputDirectory,'online_statistics'));
end
if strcmp(action,'training_plan'),report.training_plan=payload_pnn_retrain(root);end
if strcmp(action,'simulate_plan')
    report.simulation=payload_simulate_example(root,fullfile(outputDirectory,'probe'),3000001,false);
end
if strcmp(action,'simulate')
    report.simulation=payload_simulate_example(root,fullfile(outputDirectory,'probe'),3000001,true);
    report.new_trajectories=report.simulation.new_episodes_generated;
end
if strcmp(action,'hardware_dry_run')
    addpath(fullfile(root,'project'));
    R=run_robot_control(struct('mode','dry_run','action','inspect'));
    assert(~R.hardware_opened,'payload:Hardware','Dry-run unexpectedly opened hardware.');
    save(fullfile(outputDirectory,'hardware_dry_run.mat'),'R');
    report.interface=struct('hardware_opened',R.hardware_opened, ...
        'mode',R.mode,'action',R.action,'preflight_ready',R.preflight.ready);
end
report.completed_utc=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));
payload_pnn_write_json(fullfile(outputDirectory,'PIPELINE_COMPLETE.json'),report);
fprintf('PIPELINE_COMPLETE: %s\n',outputDirectory);
end
