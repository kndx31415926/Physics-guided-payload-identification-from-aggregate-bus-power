function cfg = startup_bpil()
%STARTUP_BPIL Configure this independent MATLAB research checkout.
root=fileparts(mfilename('fullpath'));
addpath(fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
cfg=bpil_config(root);
end
