function [state,report]=bpil_ring_update(cfg,state,obs,eta,teacher)
% UNKNOWN-LOAD truth is deliberately absent from this function signature.
% Historical examples retain their acquisition-time calibration context.
report=struct('teacher_accepted',teacher.accepted,'trained',false, ...
    'deployed',false,'reason','teacher_rejected','old_validation_loss',NaN, ...
    'new_validation_loss',NaN,'replay_count',size(state.replay_X,1));
if ~teacher.accepted,return;end
x=bpil_features(obs,eta);
state.replay_X(end+1,:)=x;state.replay_theta(end+1,:)=teacher.theta;
state.replay_model_version(end+1,1)=state.calibration_version;
keep=max(1,size(state.replay_X,1)-cfg.learning.replay_capacity+1):size(state.replay_X,1);
state.replay_X=state.replay_X(keep,:);state.replay_theta=state.replay_theta(keep,:);
state.replay_model_version=state.replay_model_version(keep,:);
report.replay_count=size(state.replay_X,1);
if report.replay_count<cfg.learning.min_online_labels
    report.reason='collecting_independent_episodes';return;
end
X=[state.bootstrap.X;state.replay_X];T=[state.bootstrap.theta;state.replay_theta];
w=[ones(size(state.bootstrap.X,1),1);cfg.learning.online_weight*ones(report.replay_count,1)];
candidate=bpil_train_student(cfg,X,T,w,cfg.learning.seed+state.update_count+1);
old=bpil_student_predict(state.student,state.validation.X);
new=bpil_student_predict(candidate,state.validation.X);
oldloss=mean(((old-state.validation.theta)./cfg.parameter_scale).^2,'all');
newloss=mean(((new-state.validation.theta)./cfg.parameter_scale).^2,'all');
% A fixed simulation holdout is a regression gate, never a real-world guarantee.
report.trained=true;report.old_validation_loss=oldloss;report.new_validation_loss=newloss;
report.reason='offline_regression_gate_rejected';
state.update_count=state.update_count+1;
if newloss<=cfg.learning.validation_ratio_limit*state.initial_validation_loss
    state.student=candidate;report.deployed=true;report.reason='accepted';
end
end
