function s=pfl_spec(anchor,mode)
%PFL_SPEC Prespecified affine/nonlinear ablation; never inspect test outcomes.
% The six affine lambdas and six nonlinear (architecture,lambda) candidates
% have equal search counts, not identical search spaces or functional L2.
mode=char(mode);assert(ismember(mode,{'tinySmoke','futurefull'}),'pfl:Mode','Unknown mode.');
assert(isfield(anchor,'primary_method')&&isfield(anchor,'spec'),'pfl:Anchor','Frozen anchor required.');
k=find(strcmp({anchor.methods.name},anchor.primary_method));
assert(isscalar(k)&&strcmp(anchor.methods(k).kind,'NN')&&~isempty(anchor.methods(k).model.skip), ...
    'pfl:Anchor','The locked primary must have a ridge skip.');
p=anchor.methods(k);old=anchor.spec;
fields={'network_seeds','nn_layers','nn_lambdas','skip_alphas','max_epochs','patience', ...
    'checkpoint_every','batch_size','learn_rate','adam_beta1','adam_beta2','adam_epsilon', ...
    'smooth_epsilon','loss_scales','residual_scale_floor','required_conditions','bounds'};
assert(all(isfield(old,fields)),'pfl:Anchor','Frozen optimizer specification is incomplete.');
s=struct('schema','pfl_fair_ablation_spec_v1','mode',mode,'input',p.input, ...
    'anchor_method',anchor.primary_method,'linear_lambdas',[1e-7 1e-6 1e-5 1e-4 1e-3 1e-2], ...
    'fixed_layers',p.model.members{1}.options.layers,'fixed_lambda',p.selection.lambda, ...
    'fixed_alpha',p.model.alpha,'stop_after_epoch',Inf,'full_run_authorized',false);
for i=1:numel(fields),s.(fields{i})=old.(fields{i});end
s.min_eligible_per_condition=2;
if strcmp(mode,'futurefull')
    s.min_eligible_per_condition=old.min_eligible_per_condition;
else
    s.max_epochs=2;s.patience=3;s.batch_size=32;s.checkpoint_every=1;
end
s.non_scientific_smoke=strcmp(mode,'tinySmoke');
s.selection_rule='Validation: worst condition/target MAE ratio to frozen ridge13, then mean ratio, then physical mean; strict ties keep first candidate.';
s.statistical_unit='Independent payload object; training/validation contain one episode per object. Future four-condition tests must cluster/pair by object, not time sample or seed.';
s.search_caveat='Six nonlinear architecture/lambda pairs versus six affine lambdas; equal counts are not identical hypothesis spaces. Affine range includes 1e-7; nonlinear range starts at 1e-6. Same parameter-L2 lambda does not imply equal function regularization.';
s.fixed_pair_rule='Frozen primary architecture/lambda/alpha, same inputs/skip/scaling/physical loss/Adam/seeds/stopping; replace hidden tanh layers with one affine output. No new alpha selection for this pair. Identical seed integers do not imply identical batch permutations across architectures because network initialization consumes different random draws.';
end
