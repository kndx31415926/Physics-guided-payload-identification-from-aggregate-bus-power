function report=pix_test_contracts()
%PIX_TEST_CONTRACTS Tiny simulation and physical identities; no fitting/I/O.
% Caller controls MATLAB startup. Does not create workers or access hardware.
wall=tic;caller_rng=rng;restore_rng=onCleanup(@()rng(caller_rng)); %#ok<NASGU>
root=fileparts(fileparts(mfilename('fullpath')));addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
rng_checks=struct('entry',{},'unchanged',{});
cfg=bpil_config(root);S=checked('pix_config',@()pix_config(cfg));seed=2096110601;
C0=checked('pix_condition_0',@()pix_condition(S,'combined',0,seed));
C1=checked('pix_condition_1',@()pix_condition(S,'combined',1,seed));
Cagain=checked('pix_condition_repeat',@()pix_condition(S,'combined',1,seed));
assert(isequaln(C1,Cagain),'pix:Test','Nuisance reproducibility failed.');
assert(all(C0.link_mass_scale==1)&&all(C0.resistance_scale==1)&&C0.alpha_per_K==0,'pix:Test','Zero severity mismatch.');
Cm=checked('pix_condition_mechanical',@()pix_condition(S,'mechanical',1,seed));
Ce=checked('pix_condition_electrical',@()pix_condition(S,'electrical',1,seed));
assert(isequal(Cm.link_mass_scale,C1.link_mass_scale)&&all(Cm.resistance_scale==1),'pix:Test','Mechanical isolation failed.');
assert(isequal(Ce.resistance_scale,C1.resistance_scale)&&all(Ce.link_mass_scale==1),'pix:Test','Electrical isolation failed.');
Ch=checked('pix_condition_half',@()pix_condition(S,'combined',.5,seed));
Cmh=checked('pix_condition_mechanical_half',@()pix_condition(S,'mechanical',.5,seed));
Ceh=checked('pix_condition_electrical_half',@()pix_condition(S,'electrical',.5,seed));
numeric_names=fieldnames(C0);
for j=1:numel(numeric_names)
    key=numeric_names{j};
    if isnumeric(C0.(key))
        midpoint=(C0.(key)+C1.(key))/2;
        assert(all(abs(Ch.(key)-midpoint)<=1e-12*max(1,abs(midpoint)),'all'), ...
            'pix:Test','Severity .5 is not the prescribed midpoint for %s.',key);
    end
end
assert(isequal(Cmh.link_mass_scale,Ch.link_mass_scale)&&all(Cmh.resistance_scale==1)&&Cmh.alpha_per_K==0, ...
    'pix:Test','Severity .5 mechanical/electrical isolation failed.');
assert(isequal(Ceh.resistance_scale,Ch.resistance_scale)&&all(Ceh.link_mass_scale==1)&&all(Ceh.stribeck_Nm==0), ...
    'pix:Test','Severity .5 electrical/mechanical isolation failed.');
payload=struct('mass',.15,'com',[.12 0 .004],'dimensions_m',cfg.payload.dimensions_m);
model=checked('pix_make_plant',@()pix_make_plant(cfg,payload,C0,S));q=[.1 -.6 .8 -.2];
eta=struct('coefficients',cfg.legacy.power.coefficients);
comparison_rng=rng;
[P,detail]=bpil_predict_power(cfg,q,[payload.mass payload.com(1) payload.com(3)],eta);
comparison_rng_changed=~isequaln(rng,comparison_rng);
g=gravityTorque(model.robot,q);
assert(norm(g-detail.torque_model_Nm,inf)<1e-10,'pix:Test','Independent gravity/frame construction differs.');
assert(abs(P-(S.auxiliary_W+sum(S.R25_ohm.*(g./S.K_Nm_per_A).^2)))<1e-10,'pix:Test','Cold static calibration mismatch.');
M=massMatrix(model.robot,q);assert(min(eig(M))>0,'pix:Test','Mass matrix is not SPD.');
model1=checked('pix_make_plant_stressed',@()pix_make_plant(cfg,payload,C1,S));
x=[q .02 -.01 .03 -.02 .1 -.2 .15 -.1 zeros(1,4) C1.initial_temperature_C zeros(1,8)].';
[dx,D]=checked('pix_rhs',@()pix_rhs(.31,x,q,model1));
assert(all(isfinite(dx))&&abs(D.energy_identity_residual_W)<1e-10&&D.bridge_loss_W>=0&&D.friction_W>=0,'pix:Test','Electrical algebraic power balance failed.');
assert(norm(S.K_Nm_per_A-S.K_Vs_per_rad)==0,'pix:Test','DC reciprocity failed.');
% An unsaturated command must not disable integration because division and
% multiplication by K fail to reconstruct the torque bit-for-bit.
quiet=x;quiet(5:16)=0;quiet(17:20)=S.ambient_C;
for delta=[.00037 .00113 -.00217]
    target=q+delta*[1 -.7 .3 -.9];derivative=checked('pix_rhs_unsaturated',@()pix_rhs(.31,quiet,target,model));
    expected_integral=S.ki.*(target-q);
    assert(max(abs(derivative(13:16).'-expected_integral))<1e-12, ...
        'pix:Test','Unsaturated integration is spuriously blocked.');
end
% Thermal increase must change resistance only for the electrically stressed
% plant, without modifying the payload or the estimator's nominal cfg.
hot=x;hot(17:20)=hot(17:20)+20;[~,Dh]=checked('pix_rhs_hot',@()pix_rhs(.31,hot,q,model1));
assert(all(Dh.resistance_ohm>D.resistance_ohm),'pix:Test','Thermal resistance coupling missing.');
% Potential-energy derivative independently checks gravity sign/frame.
h=1e-6;xp=x;xm=x;xp(1:4)=x(1:4)+h*x(5:8);xm(1:4)=x(1:4)-h*x(5:8);
Ep=checked('pix_energy_plus',@()pix_energy(model1,xp));
Em=checked('pix_energy_minus',@()pix_energy(model1,xm));
assert(abs((Ep.potential_J-Em.potential_J)/(2*h)-gravityTorque(model1.robot,q)*x(5:8))<1e-7,'pix:Test','Gravity/potential sign mismatch.');
% One 0.24-second, one-pose integration is a numerical smoke, not evidence
% of eight-pose estimation accuracy or stationary acceptance.
tiny=cfg;tiny.sim.initial_hold_s=.02;tiny.sim.move_s=.02;tiny.sim.hold_s=.20;
probe=struct('id','pix_contract_only','poses',q);
comm=struct('command_delay_s',[.010 .015],'encoder_delay_s',[.010 .015],'seed',2096110701);
base_clock=tic;[obs,truth]=checked('pix_simulate_probe',@()pix_simulate_probe(tiny,payload,probe,C0,2096110801,comm,S));base_wall=toc(base_clock);
assert(truth.simulated_duration_s>=.24-1e-9&&isempty(truth.integration_error),'pix:Test','Tiny ODE integration incomplete.');
assert(truth.energy.pass,'pix:Test','Integrated physical energy balance failed.');
assert(numel(obs.t)==24&&isequal(size(obs.q),[24 4])&&all(diff(obs.t)>0),'pix:Test','Observation sampling mismatch.');
assert(~any(isfield(obs,{'payload','theta_true','condition','tau','current_A','temperature_C'})),'pix:Test','Hidden plant fields leaked into observations.');
assert(all(obs.communication.power_record_encoder_receive_t<=obs.t+1e-12),'pix:Test','Future encoder information leaked.');
% Independently tighten tolerances and maximum integration step. Compare
% actual physical states and integrated bus energy, not quantized/noisy
% observations or payload-estimation accuracy. Thresholds are numerical
% QA choices, substantially below the encoder quantum and sensor noise.
strict=S;strict.rel_tol=S.rel_tol/4;strict.abs_tol=S.abs_tol/4;strict.max_step_s=S.max_step_s/2;
strict_clock=tic;[obs2,truth2]=checked('pix_simulate_probe_refined',@()pix_simulate_probe(tiny,payload,probe,C0,2096110801,comm,strict));strict_wall=toc(strict_clock);
assert(truth2.simulated_duration_s>=.24-1e-9&&isempty(truth2.integration_error)&&truth2.energy.pass, ...
    'pix:Test','Tighter micro integration or energy balance failed.');
assert(isequal(obs.t,obs2.t),'pix:Test','Numerical refinement changed observation grid.');
differences=struct('q_rad',max(abs(truth.q-truth2.q),[],'all'), ...
    'dq_rad_s',max(abs(truth.dq-truth2.dq),[],'all'), ...
    'current_A',max(abs(truth.current_A-truth2.current_A),[],'all'), ...
    'temperature_K',max(abs(truth.temperature_C-truth2.temperature_C),[],'all'), ...
    'bus_energy_J',abs(truth.energy.ledger_J(1)-truth2.energy.ledger_J(1)));
thresholds=struct('q_rad',5e-5,'dq_rad_s',5e-4,'current_A',5e-4, ...
    'temperature_K',5e-5,'bus_energy_J',1e-4*max(1,abs(truth2.energy.ledger_J(1))));
for key=fieldnames(differences).'
    assert(differences.(key{1})<=thresholds.(key{1}),'pix:Test', ...
        'Micro numerical convergence threshold failed for %s.',key{1});
end
rng_unchanged=all([rng_checks.unchanged]);
report=struct('passed',true,'checks',16,'tiny_duration_s',truth.simulated_duration_s, ...
    'energy',truth.energy,'rhs_calls',truth.ode_rhs_calls, ...
    'refined_energy',truth2.energy,'refined_rhs_calls',truth2.ode_rhs_calls, ...
    'convergence_differences',differences,'convergence_thresholds',thresholds, ...
    'rng_unchanged',rng_unchanged,'rng_checks',rng_checks,'comparison_rng_changed',comparison_rng_changed, ...
    'rng_scope','Per PIX public-entry checks; original bpil_predict_power is a separate comparator. Harness restores its entry RNG on exit.', ...
    'wallclock_diagnostic_s',struct('total',toc(wall),'base',base_wall,'refined',strict_wall), ...
    'scope','Contract and two 0.24 s integrations only; host timing is diagnostic, not a real-time or accuracy claim.');
    function varargout=checked(name,fun)
        before=rng;[varargout{1:nargout}]=fun();unchanged=isequaln(rng,before);
        rng_checks(end+1)=struct('entry',name,'unchanged',unchanged); %#ok<AGROW>
        assert(unchanged,'pix:Test','Public entry %s changed the caller RNG.',name);
    end
end
