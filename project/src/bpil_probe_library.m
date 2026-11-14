function probes = bpil_probe_library(cfg) %#ok<INUSD>
%BPIL_PROBE_LIBRARY Fixed payload-independent slow multi-posture hefting.
% All angles are reduced-model radians; hardware mapping is uncalibrated.
% Equal eight-posture budgets permit fair comparison of probe information.
A=[-20 -55 40 -25; -10 -50 50 -15; 0 -45 60 -5; 10 -40 65 10; ...
   20 -35 55 25; 10 -30 45 40; 0 -40 50 20; -10 -50 45 0];
B=[-15 -55 45 -30; 0 -40 45 -10; 15 -50 65 5; 25 -30 50 25; ...
   10 -45 55 40; -5 -25 40 45; -20 -40 65 20; 0 -50 50 -15];
C=[0 -55 45 -20; 0 -50 50 -10; 0 -45 55 0; 0 -40 60 10; ...
   0 -35 55 20; 0 -30 50 30; 0 -25 45 40; 0 -20 40 45];
sets={A,B,C};names={'balanced_heft','spread_heft','planar_heft'};
probes=repmat(struct('id','','name','','poses',zeros(8,4)),1,3);
for k=1:3
    probes(k).id=sprintf('probe_%02d',k);probes(k).name=names{k};
    probes(k).poses=sets{k}*pi/180;
end
end
