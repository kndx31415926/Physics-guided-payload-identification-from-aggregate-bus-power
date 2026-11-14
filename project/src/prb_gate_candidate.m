function gate=prb_gate_candidate(old,current,nominal_loss,initial_nominal_loss,spec)
%PRB_GATE_CANDIDATE Predeclared development heuristics, not error guarantees.
required=max(spec.gate_min_absolute_improvement,spec.gate_min_relative_improvement*old.loss);
gate=struct('pass',false,'required_improvement',required, ...
    'actual_improvement',old.loss-current.loss,'improvement_pass',false, ...
    'component_pass',false,'worst_reference_pass',false,'coverage_pass',false, ...
    'nominal_pass',false,'reasons',{{}});
gate.improvement_pass=isfinite(current.loss)&&isfinite(old.loss)&& ...
    current.loss<=old.loss-required;
gate.component_pass=all(isfinite(current.component_mae))&& ...
    all(current.component_mae<=old.component_mae+reshape(spec.gate_component_mae_tolerance,1,3));
gate.worst_reference_pass=isfinite(current.worst_loss)&& ...
    current.worst_loss<=old.worst_loss*(1+spec.gate_worst_relative_tolerance)+spec.gate_worst_absolute_tolerance;
gate.coverage_pass=current.usable&&current.teacher_accepted_count>=old.teacher_accepted_count;
gate.nominal_pass=isfinite(nominal_loss)&&nominal_loss<=spec.nominal_gate_ratio*initial_nominal_loss;
checks={'improvement','component','worst_reference','coverage','nominal'};
for j=1:numel(checks)
    if ~gate.([checks{j} '_pass']),gate.reasons{end+1}=[checks{j} '_gate_rejected'];end
end
gate.pass=isempty(gate.reasons);
end
