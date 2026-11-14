function report=pix_diagnose_rng()
%PIX_DIAGNOSE_RNG Read-only micro diagnosis, no full probe or model fitting.
entry=rng;cleanup=onCleanup(@()rng(entry)); %#ok<NASGU>
root=fileparts(fileparts(mfilename('fullpath')));addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
rows=struct('entry',{},'rng_unchanged',{},'elapsed_s',{});
cfg=check('bpil_config',@()bpil_config(root));
S=check('pix_config',@()pix_config(cfg));
C=check('pix_condition',@()pix_condition(S,'combined',0,2096110601));
check('rigidBodyTree_constructor',@()rigidBodyTree('DataFormat','row'));
check('rigidBody_constructor',@()rigidBody('pix_rng_body'));
check('rigidBodyJoint_constructor',@()rigidBodyJoint('pix_rng_joint','revolute'));
payload=struct('mass',.15,'com',[.12 0 .004],'dimensions_m',cfg.payload.dimensions_m);
model=check('pix_make_plant',@()pix_make_plant(cfg,payload,C,S));
q=[.1 -.6 .8 -.2];
check('gravityTorque',@()gravityTorque(model.robot,q));
check('massMatrix',@()massMatrix(model.robot,q));
eta=struct('coefficients',cfg.legacy.power.coefficients);
check('bpil_predict_power_comparator',@()bpil_predict_power(cfg,q,[.15 .12 .004],eta));
x=[q zeros(1,12) C.initial_temperature_C zeros(1,8)].';
check('pix_rhs',@()pix_rhs(.03,x,q,model));
check('pix_energy',@()pix_energy(model,x));
tiny=cfg;tiny.sim.initial_hold_s=.02;tiny.sim.move_s=.02;tiny.sim.hold_s=.20;
probe=struct('id','pix_rng_micro_only','poses',q);
comm=struct('command_delay_s',[.010 .015],'encoder_delay_s',[.010 .015],'seed',2096110701);
check('pix_simulate_probe_0p24s',@()pix_simulate_probe(tiny,payload,probe,C,2096110801,comm,S));
report=struct('rows',rows,'scope','One 0.24 s probe; no feature fitting, training, hardware or frozen-run writes.');
disp(jsonencode(report));
    function value=check(name,fun)
        before=rng;t=tic;value=fun();elapsed=toc(t);after=rng;
        rows(end+1)=struct('entry',name,'rng_unchanged',isequaln(before,after),'elapsed_s',elapsed); %#ok<AGROW>
    end
end
