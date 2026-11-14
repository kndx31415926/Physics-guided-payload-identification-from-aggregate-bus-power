function prc_validate_dataset(D,plan,indices)
% Reject cross-run records, split drift or labels inconsistent with the plan.
O=plan.objects(indices,:);ids=double(O.object_id);
assert(isequal(double(D.object_id(:)),ids(:)),'prc:Identity','Data/plan object IDs differ.');
assert(isequal(string(D.split(:)),string(O.split(:))),'prc:Split','Data/plan splits differ.');
expected=[O.mass_kg O.cx_m O.cz_m];
assert(isequal(size(expected),size(D.theta))&&all(abs(expected-D.theta)<1e-12,'all'), ...
    'prc:Labels','Saved record labels differ from the source plan.');
for i=1:numel(ids)
    assert(strcmp(D.provenance(i).record_run_id,plan.spec.run_id), ...
        'prc:RunIdentity','Record comes from a different run.');
    assert(strcmp(D.provenance(i).record_plan_signature,plan.plan_signature), ...
        'prc:PlanIdentity','Record plan signature differs.');
end
end
