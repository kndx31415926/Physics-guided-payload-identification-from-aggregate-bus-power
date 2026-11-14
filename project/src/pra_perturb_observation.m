function [out,meta]=pra_perturb_observation(obs,cfg,condition,seed)
%PRA_PERTURB_OBSERVATION Readout-only stress, without simulator truth.
% C=pra_perturb_observation('conditions') returns the prespecified matrix.
% Coarser quantization acts on already sampled/quantized encoder readings;
% it does not reproduce changed feedback inside the low-level controller.
if nargin==1&&(ischar(obs)||isstring(obs))&&strcmp(string(obs),"conditions")
    out=conditions();meta=[];return
end
if nargin<4,seed=0;end
assert(isstruct(obs)&&isscalar(obs)&&all(isfield(obs, ...
    {'t','q','P','q_command','plateau_q','plateau_P','plateau_sd_P','stationary','probe_id'})), ...
    'pra:Observation','Expected deployable observation fields.');
required={'id','randomized','target_power_std_W','power_bias_W','power_gain','encoder_counts','pitch_bias_ticks'};
assert(isstruct(condition)&&isscalar(condition)&&all(isfield(condition,required)), ...
    'pra:Perturbation','Invalid condition specification.');
t=double(obs.t(:));q=double(obs.q);P=double(obs.P(:));n=numel(t);
assert(n>1&&isequal(size(q),[n 4])&&isequal(size(obs.q_command),size(q))&&numel(P)==n&& ...
    all(isfinite([t q P]),'all')&&all(diff(t)>0),'pra:Observation','Invalid synchronized readings.');
assert(isscalar(seed)&&seed>=0&&seed<=2^32-1&&seed==floor(seed),'pra:Seed','Invalid seed.');
base_sigma=double(cfg.sensor.power_std_W);target=double(condition.target_power_std_W);
assert(target>=base_sigma&&isfinite(target)&&isfinite(condition.power_bias_W)&& ...
    isfinite(condition.power_gain)&&condition.power_gain>0&& ...
    any(condition.encoder_counts==[4096 2048 1024])&&isfinite(condition.pitch_bias_ticks), ...
    'pra:Perturbation','Unsupported perturbation magnitude.');
additional_sigma=sqrt(max(0,target^2-base_sigma^2));
assert(logical(condition.randomized)==(additional_sigma>0),'pra:Perturbation','Randomized flag disagrees with noise.');
old=rng;cleanup=onCleanup(@()rng(old)); %#ok<NASGU>
rng(seed,'twister');
if additional_sigma>0,P=P+additional_sigma*randn(n,1);end
P=condition.power_gain*P+condition.power_bias_W;
nominal_quantum=2*pi/4096;
if condition.encoder_counts<4096
    quantum=2*pi/condition.encoder_counts;q=round(q/quantum)*quantum;
end
q(:,2:4)=q(:,2:4)+condition.pitch_bias_ticks*nominal_quantum*[1 -1 1];
out=obs;out.P=P;out.q=q;
% Recompute every measured summary used by the estimators. Keep commands and
% their timing intact: this experiment changes estimator readout only.
N=size(obs.plateau_q,1);pq=nan(N,4);pp=nan(N,1);sd=nan(N,1);stationary=false(N,1);
window=min(.3,cfg.sim.hold_s/2);cycle=cfg.sim.move_s+cfg.sim.hold_s;
for j=1:N
    finish=cfg.sim.initial_hold_s+j*cycle;
    use=t>=finish-window-1e-10&t<=finish+1e-10;
    if sum(use)<max(10,round(window*80)),continue,end
    sample=q(use,:);pq(j,:)=mean(sample,1);pp(j)=mean(P(use));sd(j)=std(P(use));
    stationary(j)=norm(sample(end,:)-sample(1,:))/window<.035&& ...
        max(max(sample,[],1)-min(sample,[],1))<.012;
end
out.plateau_q=pq;out.plateau_P=pp;out.plateau_sd_P=sd;out.stationary=stationary;
meta=struct('schema','pra_observation_stress_v1','condition',condition,'seed',seed, ...
    'additional_power_std_W',additional_sigma, ...
    'nominal_total_power_std_W',condition.power_gain*target, ...
    'encoder_quantum_rad',2*pi/condition.encoder_counts,'stationary_count',sum(stationary), ...
    'scope',['Readout-only perturbation of recorded P and encoder q; no simulator truth; ', ...
    'coarsening existing quantization; no change to control, mechanics or actual trajectory.']);
end

function C=conditions()
base=struct('id','nominal','randomized',false,'target_power_std_W',.03, ...
    'power_bias_W',0,'power_gain',1,'encoder_counts',4096,'pitch_bias_ticks',0);
C=repmat(base,12,1);
C(2).id='power_noise_0p09';C(2).target_power_std_W=.09;C(2).randomized=true;
C(3).id='power_noise_0p15';C(3).target_power_std_W=.15;C(3).randomized=true;
C(4).id='power_bias_minus_0p10';C(4).power_bias_W=-.10;
C(5).id='power_bias_plus_0p10';C(5).power_bias_W=.10;
C(6).id='power_gain_0p97';C(6).power_gain=.97;
C(7).id='power_gain_1p03';C(7).power_gain=1.03;
C(8).id='encoder_2048';C(8).encoder_counts=2048;
C(9).id='encoder_1024';C(9).encoder_counts=1024;
C(10).id='pitch_bias_minus_tick';C(10).pitch_bias_ticks=-1;
C(11).id='pitch_bias_plus_tick';C(11).pitch_bias_ticks=1;
C(12).id='combined';C(12).target_power_std_W=.15;C(12).randomized=true;
C(12).power_bias_W=.10;C(12).encoder_counts=1024;
end
