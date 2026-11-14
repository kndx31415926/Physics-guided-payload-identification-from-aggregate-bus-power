function f=psf_features(obs,probe_id)
%PSF_FEATURES Exact same eight steady q/P observations available to physics.
% Input is observation only: no truth, command tracking, IDs or transients.
if nargin<2,probe_id='probe_02';end
f=struct('schema','psf_steady_qps_v1','usable',false,'x',nan(1,40),'x48',nan(1,48),'reason','');
try
    assert(isstruct(obs)&&isscalar(obs)&&all(isfield(obs,{'plateau_q','plateau_P','plateau_sd_P','stationary','probe_id'})), ...
        'psf:Observation','Missing steady observation fields.');
    assert(strcmp(string(obs.probe_id),string(probe_id))&&isequal(size(obs.plateau_q),[8 4])&& ...
        numel(obs.plateau_P)==8&&numel(obs.stationary)==8&&all(obs.stationary(:)==1), ...
        'psf:Observation','Expected eight stationary plateaus in the fixed order.');
    Q=double(obs.plateau_q);P=double(obs.plateau_P(:));sd=double(obs.plateau_sd_P(:));
    assert(numel(sd)==8&&all(sd>=0)&&all(isfinite([Q P sd]),'all'),'psf:Observation','Nonfinite steady values.');
    % Per-pose order q1,q2,q3,q4,P. Standardization is fitted on train only.
    f.x=reshape([Q P].',1,40);f.x48=reshape([Q P sd].',1,48);f.usable=true;
catch err,f.reason=err.identifier;end
end
