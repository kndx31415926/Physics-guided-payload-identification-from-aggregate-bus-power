function [probe,diagnostic] = bpil_select_probe(cfg,probes,theta,eta)
%BPIL_SELECT_PROBE Select largest minimum scaled static-power singular value.
% Uses only a parameter estimate and candidate commanded poses, never truth.
assert(~isempty(probes),'bpil:Probes','No candidate probes.');
B=cfg.ident.bounds;assert(isequal(size(B),[3 2]),'bpil:Bounds','Invalid bounds.');
span=(B(:,2)-B(:,1)).';sigma=cfg.ident.power_sigma_W;
assert(all(span>0)&&isfinite(sigma)&&sigma>0,'bpil:Scaling','Invalid sensitivity scaling.');
if isnumeric(probes),count=size(probes,1);else,count=numel(probes);end
scores=zeros(count,1);conditions=inf(count,1);spectra=zeros(count,3);
for k=1:count
    if isnumeric(probes),q=probes(k,:);
    elseif isfield(probes,'poses'),q=probes(k).poses;
    elseif isfield(probes,'plateau_q'),q=probes(k).plateau_q;
    elseif isfield(probes,'q'),q=probes(k).q;
    else,error('bpil:Probes','Probe must expose poses, plateau_q, or q.');end
    if isfield(cfg.ident,'previous_q'),q=[cfg.ident.previous_q;q];end
    [~,D]=bpil_predict_power(cfg,q,theta,eta);
    s=svd(D.jacobian.*span/sigma,0);s=s(:);s(end+1:3,1)=0;
    spectra(k,:)=s(1:3).';scores(k)=s(3);
    if s(3)>eps(max([1;s])),conditions(k)=s(1)/s(3);end
end
[~,selected]=max(scores);
if isnumeric(probes),probe=probes(selected,:);else,probe=probes(selected);end
diagnostic=struct('selected_index',selected,'minimum_singular_values',scores, ...
    'singular_values',spectra,'conditions',conditions, ...
    'selected_is_full_rank',isfinite(conditions(selected)), ...
    'scope','Local static sensitivity at the supplied estimate; not a global identifiability guarantee.');
end
