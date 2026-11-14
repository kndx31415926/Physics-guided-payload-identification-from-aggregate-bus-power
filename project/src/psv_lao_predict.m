function M=psv_lao_predict(literature,cfg,obs)
% Secondary frozen method transplant. Observations only, never payload truth.
O=prc_observation(obs,cfg);D=struct('state',reshape(O.state,1,8,4,4),'g0',nan(1,8,4), ...
    'Y',nan(1,8,4,3),'usable',O.usable,'object_id',1);
if all(isfinite(O.state(:,:,1)),'all')
    [g0,Y]=bpil_static_design(cfg,O.state(:,:,1));D.g0=reshape(g0,1,8,4);D.Y=reshape(Y,1,8,4,3);
end
seeds={0,literature.model.seeds,literature.model.seeds};names={'lao_pe_transplant','lao_t_transplant','lao_ta_transplant'};
raw={nan(1,3),nan(numel(seeds{2}),3),nan(numel(seeds{3}),3)};valid={false,false(numel(seeds{2}),1),false(numel(seeds{3}),1)};
if O.usable
    P=prc_pe_predict(literature.pe,D,1);raw{1}=reshape(P.theta_raw,1,3);valid{1}=P.valid;
    T=prc_lao_predict(literature.model,D,1,'uniform');A=prc_lao_predict(literature.model,D,1,'attention');
    raw{2}=reshape(permute(T.theta_raw,[3 2 1]),[],3);raw{3}=reshape(permute(A.theta_raw,[3 2 1]),[],3);
    valid{2}=T.valid(:);valid{3}=A.valid(:);
end
M=struct([]);for m=1:3
    bounded=min(max(raw{m},cfg.ident.bounds(:,1).'),cfg.ident.bounds(:,2).');bounded(~isfinite(raw{m}))=NaN;
    item=struct('name',names{m},'budget',600,'seeds',seeds{m}(:).','raw',raw{m},'clipped',bounded,'valid',logical(valid{m}));
    if isempty(M),M=item;else,M(end+1)=item;end %#ok<AGROW>
end
end
