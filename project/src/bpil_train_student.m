function student=bpil_train_student(cfg,X,theta,weights,seed)
% Mature MATLAB neural regression; no bespoke back-propagation implementation.
if nargin<4||isempty(weights),weights=ones(size(X,1),1);end
if nargin<5,seed=cfg.learning.seed;end
rng(seed,'twister');scale=cfg.parameter_scale;
student=struct('scale',scale,'bounds',cfg.ident.bounds,'seed',seed, ...
    'model',[],'n',size(X,1),'feature_count',size(X,2),'backend','fitrnet');
student.model=fitrnet(X,theta./scale,'LayerSizes',cfg.learning.layers, ...
    'Activations','tanh','Standardize',true,'Lambda',cfg.learning.lambda, ...
    'IterationLimit',cfg.learning.iterations,'Weights',weights,'Verbose',0);
end
