function value=psf_load_case(row,cfg,spec)
% Observation-only feature extraction; labels are checked by outer scorer.
S=load(char(row.record_path),'record');r=S.record;
assert(r.object_id==row.object_id&&r.trial_id==row.trial_id,'psf:Identity','Wrong record object or trial.');
physical=isempty(r.error)&&isstruct(r.truth)&&isfield(r.truth,'physical_success')&&logical(r.truth.physical_success);
steady=psf_features(r.obs,spec.probe_id);
if row.feature_kind=="pgar"
    F=load(char(row.feature_path),'cached');c=F.cached;
    assert(c.key.object_id==row.object_id&&strcmp(string(c.key.split),row.split),'psf:Identity','Wrong training cache.');
    physics=c.features;
elseif row.feature_kind=="prt"
    F=load(char(row.feature_path),'checkpoint');c=F.checkpoint;
    assert(c.object_id==row.object_id&&strcmp(string(c.condition_id),row.condition)&&c.jitter_seed==row.jitter_seed&& ...
        strcmp(c.record_hash,prc_file_hash(char(row.record_path))),'psf:Identity','Wrong communication feature cache.');
    physics=c.prediction.features;
else
    physics=pgar_model_features(cfg,r.obs,spec.scale,spec.probe_id);
end
assert(isstruct(physics)&&isfield(physics,'residual')&&numel(physics.residual)==13,'psf:Features','Invalid physical feature cache.');
value=struct('steady',steady,'physics',physics,'physical_success',physical);
end
