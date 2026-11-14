function out=pvi_run_static_validation(run_dir)
%PVI_RUN_STATIC_VALIDATION Reproducible static identifiability study.
% This is an analytic-model validation, not servo or hardware evidence.
root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'src'));
addpath(fullfile(root,'vendor','bdcl_v29'));
if nargin<1,run_dir=fullfile(root,'results','pvi_static_20261030_v2');end
assert(~isfolder(run_dir),'pvi:Immutable','Choose a new output directory.');
mkdir(run_dir);mkdir(fullfile(run_dir,'figures'));mkdir(fullfile(run_dir,'source'));
diary(fullfile(run_dir,'run.log'));cleaner=onCleanup(@()diary('off')); %#ok<NASGU>
source=fullfile(root,'results','pgar_nominal_20261029_v1','configuration.mat');
S=load(source);assert(isfield(S,'cfg'),'pvi:Config','Frozen nominal cfg missing.');cfg=S.cfg;
spec=struct('schema','pvi_static_identifiability_v2','seed',961030, ...
 'payload_bounds',[.08 .22;.05 .19;-.018 .018], ...
 'grid_points_per_axis',11,'sigma_W',.04,'solver_grid_points',3, ...
 'solver_starts',25,'misspecification_objects',50,'noise_objects',100, ...
 'noise_levels_W',[.01 .04 .08],'noise_repeats',10, ...
 'source_config_sha256',prc_file_hash(source), ...
 'scope','Static nominal mathematics; numerical grid is not global proof; no model selection.', ...
 'reference_theta',[.09 .06 -.014;.21 .07 .014;.10 .18 .012;.20 .17 -.012]);
rng(spec.seed,'twister');B=spec.payload_bounds;span=diff(B,1,2).';mid=mean(B,2).';
coeff=cfg.legacy.power.coefficients(:).';eta=struct('coefficients',coeff);
save(fullfile(run_dir,'spec.mat'),'spec','cfg');write_text(fullfile(run_dir,'spec.json'),jsonencode(spec,PrettyPrint=true));
source_names={'pvi_run_static_validation.m','src/pvi_power_model.m','src/pvi_rank_bound.m', ...
 'src/bpil_static_design.m','src/bpil_predict_power.m','src/bpil_teacher.m', ...
 'src/bpil_probe_library.m','src/bpil_make_plant.m','src/bpil_calibrate_anchor.m', ...
 'src/prc_file_hash.m'};
V=dir(fullfile(root,'vendor','bdcl_v29','*.m'));
for j=1:numel(V),source_names{end+1}=['vendor/bdcl_v29/' V(j).name];end %#ok<AGROW>
paths=strings(numel(source_names),1);hashes=paths;
for j=1:numel(source_names)
 paths(j)=string(source_names{j});hashes(j)=string(prc_file_hash(fullfile(root,source_names{j})));
 dest=fullfile(run_dir,'source',source_names{j});if ~isfolder(fileparts(dest)),mkdir(fileparts(dest));end
 copyfile(fullfile(root,source_names{j}),dest);
end
writetable(table(paths,hashes),fullfile(run_dir,'source_manifest.csv'));
probes=bpil_probe_library(cfg);q=probes(2).poses;phi=sum(q(:,2:4),2);
qconst=q;qconst(:,4)=sum(q(1,2:4))-sum(qconst(:,2:3),2);
sets=struct('name',{'single_pose','same_pose_repeated_8','constant_tool_pitch_8', ...
 'probe02_fit6','probe02_all8','probe01_all8','probe03_all8'}, ...
 'q',{q(1,:),repmat(q(1,:),8,1),qconst,q(2:7,:),q,probes(1).poses,probes(3).poses});
for k=1:numel(sets),[sets(k).g0,sets(k).Y]=bpil_static_design(cfg,sets(k).q);end
[g0,Y]=bpil_static_design(cfg,q);grid=make_grid(B,spec.grid_points_per_axis);
fprintf('Grid: %d payloads x %d pose sets.\n',size(grid,1),numel(sets));
rows=cell(size(grid,1)*numel(sets),10);r=0;
for k=1:numel(sets)
 for i=1:size(grid,1)
  [~,~,J]=pvi_power_model(sets(k).g0,sets(k).Y,grid(i,:),coeff);
  [rk,sv,co]=spectrum(J.*span/spec.sigma_W,3);r=r+1;
  rows(r,:)={string(sets(k).name),i,grid(i,1),grid(i,2),grid(i,3),rk,sv(1),sv(2),sv(3),co};
 end
end
T=cell2table(rows,'VariableNames',{'pose_set','object_id','mass_kg','cx_m','cz_m','rank','s1','s2','s3','condition'});
writetable(T,fullfile(run_dir,'sensitivity_grid.csv'));
summary=cell(numel(sets),8);
for k=1:numel(sets)
 x=T(T.pose_set==string(sets(k).name),:);
 summary(k,:)={string(sets(k).name),height(x),min(x.rank),max(x.rank),min(x.s3),median(x.s3),max(x.s3),max(x.condition)};
end
ST=cell2table(summary,'VariableNames',{'pose_set','n_objects','min_rank','max_rank','min_s3','median_s3','max_s3','max_condition'});
writetable(ST,fullfile(run_dir,'sensitivity_summary.csv'));disp(ST);
rankbounds=struct();
for k=[4 5]
 rankbounds.(sets(k).name)=pvi_rank_bound(sets(k).g0,sets(k).Y,coeff,B,200000);
 fprintf('Continuous rank bound %s: %s\n',sets(k).name,jsonencode(rankbounds.(sets(k).name)));
end
write_text(fullfile(run_dir,'continuous_rank_bound.json'),jsonencode(rankbounds,PrettyPrint=true));
% Independent differential checks and rigidBodyTree checks, including cy.
checktheta=make_grid(B,3);max_jerr=0;max_berr=0;max_nominal_jerr=0;max_powererr=0;
max_torqueerr=0;max_cyerr=0;max_yawerr=0;max_constant_pitcherr=0;
for i=1:size(checktheta,1)
 t=checktheta(i,:);[p,Jb,J,~,tau]=pvi_power_model(g0,Y,t,coeff);
 [pp,D]=bpil_predict_power(cfg,q,t,eta);
 max_nominal_jerr=max(max_nominal_jerr,max(abs(J-D.jacobian),[],'all'));
 max_powererr=max(max_powererr,max(abs(p-pp)));
 for j=1:3
  step=1e-6*span(j);tp=t;tm=t;tp(j)=tp(j)+step;tm(j)=tm(j)-step;
  fd=(pvi_power_model(g0,Y,tp,coeff)-pvi_power_model(g0,Y,tm,coeff))/(2*step);
  max_jerr=max(max_jerr,max(abs(fd-J(:,j))));
  beta=[t(1),t(1)*t(2),t(1)*t(3)];stepb=1e-7*[.14 .04 .008];
  bp=beta;bm=beta;bp(j)=bp(j)+stepb(j);bm(j)=bm(j)-stepb(j);
  fdb=(pvi_power_model(g0,Y,[bp(1),bp(2:3)/bp(1)],coeff)- ...
   pvi_power_model(g0,Y,[bm(1),bm(2:3)/bm(1)],coeff))/(2*stepb(j));
  max_berr=max(max_berr,max(abs(fdb-Jb(:,j))));
 end
 for cy=[-.02 0 .02]
  model=bpil_make_plant(cfg,struct('mass',t(1),'com',[t(2),cy,t(3)]));
  tg=zeros(8,4);for k=1:8,tg(k,:)=gravityTorque(model.robot,q(k,:));end
  max_torqueerr=max(max_torqueerr,max(abs(tg-tau),[],'all'));
  if cy==0,tzero=tg;else,max_cyerr=max(max_cyerr,max(abs(tg-tau),[],'all'));end %#ok<NASGU>
 end
end
qy=q;qy(:,1)=qy(:,1)+.73;[gy,Yy]=bpil_static_design(cfg,qy);
max_yawerr=max(abs(pvi_power_model(gy,Yy,mid,coeff)-pvi_power_model(g0,Y,mid,coeff)));
tc=mid;tc(2:3)=tc(2:3)+.01*[sin(sum(q(1,2:4))),-cos(sum(q(1,2:4)))];
max_constant_pitcherr=max(abs(pvi_power_model(sets(3).g0,sets(3).Y,tc,coeff)- ...
 pvi_power_model(sets(3).g0,sets(3).Y,mid,coeff)));
checks=table(["theta_analytic_vs_fd";"beta_analytic_vs_fd";"independent_vs_existing_jacobian"; ...
 "independent_vs_existing_power";"analytic_torque_vs_rigidBodyTree_including_cy"; ...
 "cy_change_invariance";"yaw_change_invariance";"constant_pitch_exact_ambiguity"], ...
 [max_jerr;max_berr;max_nominal_jerr;max_powererr;max_torqueerr;max_cyerr;max_yawerr;max_constant_pitcherr], ...
 'VariableNames',{'check','max_absolute_error'});
writetable(checks,fullfile(run_dir,'analytic_checks.csv'));disp(checks);
assert(max_jerr<1e-5&&max_berr<1e-5&&max_torqueerr<1e-10&&max_constant_pitcherr<1e-10,'pvi:AnalyticCheck','Analytic validation failed.');
% Calibration sensitivity: exact local nuisance projection, no priors.
[~,~,J,H]=pvi_power_model(g0,Y,mid,coeff);A=J.*span/spec.sigma_W;
[~,~,~,H0]=pvi_power_model(g0,Y,[0 0 0],coeff);
Href=H0;
for i=1:size(spec.reference_theta,1)
 [~,~,~,Hr]=pvi_power_model(g0,Y,spec.reference_theta(i,:),coeff);Href=[Href;Hr]; %#ok<AGROW>
end
calnames={'known_eta','unknown_aux_common','unknown_aux_per_axis','common_plus_empty', ...
 'per_axis_plus_empty','per_axis_plus_empty_four_refs'};calrows=cell(6,11);caldata=cell(6,1);
for k=1:6
 switch k
  case 1,N=zeros(8,0);F=A;
  case 2,N=[H(:,1),H(:,2:4)*coeff(3:5).']/spec.sigma_W;F=A;
  case 3,N=H.*[1 coeff(3:5)]/spec.sigma_W;F=A;
  case 4,N=[[H(:,1),H(:,2:4)*coeff(3:5).'];[H0(:,1),H0(:,2:4)*coeff(3:5).']]/spec.sigma_W;F=[A;zeros(8,3)];
  case 5,N=[H;H0].*[1 coeff(3:5)]/spec.sigma_W;F=[A;zeros(8,3)];
  case 6,N=[H;Href].*[1 coeff(3:5)]/spec.sigma_W;F=[A;zeros(size(Href,1),3)];
 end
 R=F-N*pinv(N)*F;[rk,sv,co]=spectrum(R,3);[jr,~,~]=spectrum([F N],size([F N],2));
 if rk==3,C=diag(span)*inv(R.'*R)*diag(span);se=sqrt(max(0,diag(C))).';else,se=[Inf Inf Inf];end
 calrows(k,:)={string(calnames{k}),size(F,1),size(N,2),jr,rk,sv(3),co,se(1)*1e3,se(2)*1e3,se(3)*1e3,norm(R,'fro')^2/norm(F,'fro')^2};
 caldata{k}=struct('F',F,'N',N,'profiled',R);
end
CT=cell2table(calrows,'VariableNames',{'case','observations','nuisance_dim','joint_rank', ...
 'profiled_load_rank','profiled_s3','profiled_condition','ideal_std_mass_g','ideal_std_cx_mm','ideal_std_cz_mm','information_trace_fraction'});
writetable(CT,fullfile(run_dir,'calibration_confounding.csv'));disp(CT);
calA=[H0;Href(9:end,:)];[r0,s0,c0]=spectrum(H0.*[1 coeff(3:5)]/spec.sigma_W,4);
[rr,sr,cr]=spectrum(calA.*[1 coeff(3:5)]/spec.sigma_W,4);
writetable(table(["empty_only";"empty_four_known_refs"],[r0;rr],[s0(4);sr(4)],[c0;cr], ...
 'VariableNames',{'calibration_case','rank','min_singular_value','condition'}),fullfile(run_dir,'calibration_design.csv'));
% Nearest distinct payloads on a fixed 11^3 grid (no uniqueness claim).
pairrows=cell(4,13);
for k=1:4
 idx=[1 2 3 5];d=sets(idx(k));P=zeros(size(grid,1),size(d.q,1));
 for i=1:size(grid,1),P(i,:)=pvi_power_model(d.g0,d.Y,grid(i,:),coeff).';end
 pd=pdist2(P,P)/sqrt(size(P,2));pd(1:size(pd,1)+1:end)=Inf;
 % Require a material separation: >=14g mass OR >=14mm planar COM.
 far=abs(grid(:,1)-grid(:,1).')>=.013999 | pdist2(grid(:,2:3),grid(:,2:3))>=.013999;
 pd(~far)=Inf;[val,lin]=min(pd(:));[ia,ib]=ind2sub(size(pd),lin);
 pairrows(k,:)={string(d.name),ia,ib,grid(ia,1),grid(ia,2),grid(ia,3),grid(ib,1),grid(ib,2),grid(ib,3),val, ...
 val/spec.sigma_W,abs(grid(ia,1)-grid(ib,1))*1e3,norm(grid(ia,2:3)-grid(ib,2:3))*1e3};
end
PT=cell2table(pairrows,'VariableNames',{'pose_set','object_a','object_b','mass_a_kg','cx_a_m','cz_a_m', ...
 'mass_b_kg','cx_b_m','cz_b_m','power_curve_rms_difference_W','rms_over_assumed_sigma','mass_difference_g','planar_com_difference_mm'});
writetable(PT,fullfile(run_dir,'hard_payload_pairs.csv'));disp(PT);
% Multi-start exact inverse, normalized solver variables, no NN involved.
starts=[zeros(1,3);ones(1,3);.5*ones(1,3);rand(spec.solver_starts-3,3)];
options=optimoptions('lsqnonlin','Display','off','SpecifyObjectiveGradient',true, ...
 'FunctionTolerance',1e-13,'StepTolerance',1e-13,'OptimalityTolerance',1e-11,'MaxIterations',200);
solverrows=cell(size(checktheta,1)*size(starts,1),8);r=0;
for i=1:size(checktheta,1)
 p=pvi_power_model(g0,Y,checktheta(i,:),coeff);
 for s=1:size(starts,1)
  [hat,res,flag]=solve_inverse(g0,Y,p,coeff,B,starts(s,:),options);r=r+1;
  solverrows(r,:)={i,s,flag,res,abs(hat(1)-checktheta(i,1))*1e3, ...
   norm(hat(2:3)-checktheta(i,2:3))*1e3,hat(1),max(abs((hat-checktheta(i,:))./span))};
 end
end
MT=cell2table(solverrows,'VariableNames',{'object_id','start','exitflag','squared_residual_W2','mass_error_g','planar_com_error_mm','mass_estimate_kg','max_scaled_parameter_error'});
writetable(MT,fullfile(run_dir,'multistart_inverse.csv'));
fprintf('Multistart: %d solves, worst scaled error %.3g.\n',height(MT),max(MT.max_scaled_parameter_error));
% Model error sensitivity: independent imposed electrical/torque deviations.
targets=B(:,1).'+rand(spec.misspecification_objects,3).*span;
cases={'matched','aux_plus_0p1W','common_hold_plus3pct','axis2_hold_plus5pct','axis3_hold_plus5pct', ...
 'axis4_hold_plus5pct','all_torque_scale_plus1pct','wrist_static_bias_plus0p01Nm'};
MR=cell(numel(cases)*size(targets,1),7);r=0;
for k=1:numel(cases)
 for i=1:size(targets,1)
  [~,~,~,~,tt]=pvi_power_model(g0,Y,targets(i,:),coeff);cc=coeff;
  switch k
   case 2,cc(1)=cc(1)+.1;
   case 3,cc(3:5)=cc(3:5)*1.03;
   case 4,cc(3)=cc(3)*1.05;
   case 5,cc(4)=cc(4)*1.05;
   case 6,cc(5)=cc(5)*1.05;
   case 7,tt=tt*1.01;
   case 8,tt(:,4)=tt(:,4)+.01;
  end
  p=cc(1)+sum(tt.^2.*cc(2:5),2);[hat,res,flag]=solve_inverse(g0,Y,p,coeff,B,.5*ones(1,3),options);r=r+1;
  MR(r,:)={string(cases{k}),i,abs(hat(1)-targets(i,1))*1e3,norm(hat(2:3)-targets(i,2:3))*1e3,sqrt(res/8),flag,any(abs(hat-B(:,1).')<1e-8|abs(hat-B(:,2).')<1e-8)};
 end
end
MM=cell2table(MR,'VariableNames',{'case','object_id','mass_error_g','planar_com_error_mm','fit_rmse_W','exitflag','bound_hit'});
writetable(MM,fullfile(run_dir,'misspecification_predictions.csv'));MS=metric_summary(MM);writetable(MS,fullfile(run_dir,'misspecification_summary.csv'));disp(MS);
% Conditional noise floor. iid Gaussian noise applies to each pose summary,
% not to every raw 100-Hz sample; no sqrt(N_raw) noise reduction is assumed.
targets=B(:,1).'+rand(spec.noise_objects,3).*span;NR=cell(numel(spec.noise_levels_W)*size(targets,1)*spec.noise_repeats,7);r=0;
for k=1:numel(spec.noise_levels_W)
 for i=1:size(targets,1)
  p=pvi_power_model(g0,Y,targets(i,:),coeff);
  for rep=1:spec.noise_repeats
   pp=p+spec.noise_levels_W(k)*randn(8,1);[hat,res,flag]=solve_inverse(g0,Y,pp,coeff,B,.5*ones(1,3),options);r=r+1;
   NR(r,:)={"sigma_"+string(spec.noise_levels_W(k)),i,abs(hat(1)-targets(i,1))*1e3,norm(hat(2:3)-targets(i,2:3))*1e3,sqrt(res/8),flag,any(abs(hat-B(:,1).')<1e-8|abs(hat-B(:,2).')<1e-8)};
  end
 end
end
NT=cell2table(NR,'VariableNames',MM.Properties.VariableNames);NS=metric_summary(NT);
writetable(NT,fullfile(run_dir,'noise_predictions.csv'));writetable(NS,fullfile(run_dir,'noise_summary.csv'));disp(NS);
% Exact scale gauge if the empty-arm gravity scale is ALSO unknown.
gauge_scale=1.03;t2=mid;t2(1)=gauge_scale*t2(1);cc=coeff;cc(3:5)=cc(3:5)/gauge_scale^2;
gaugeerr=max(abs(pvi_power_model(gauge_scale*g0,Y,t2,cc)-pvi_power_model(g0,Y,mid,coeff)));
assert(gaugeerr<1e-10,'pvi:Gauge','Scale gauge calculation failed.');
% Source immutability verified after numerical work.
for j=1:numel(source_names),assert(strcmp(hashes(j),prc_file_hash(fullfile(root,source_names{j}))),'pvi:SourceChanged','Source changed during validation.');end
out=struct('spec',spec,'sensitivity_summary',ST,'analytic_checks',checks,'calibration',CT,'rank_bounds',rankbounds, ...
 'hard_pairs',PT,'misspecification',MS,'noise',NS,'gauge_max_error_W',gaugeerr, ...
 'multistart_count',height(MT),'multistart_max_scaled_error',max(MT.max_scaled_parameter_error));
save(fullfile(run_dir,'validation.mat'),'out','T','CT','PT','MT','MM','NT','sets','caldata','starts','-v7.3');
make_figures(run_dir,T,CT,MS,NS);
write_text(fullfile(run_dir,'COMPLETE.json'),jsonencode(struct('status','complete','schema',spec.schema, ...
 'finished_utc',char(datetime('now','TimeZone','UTC','Format',"yyyy-MM-dd'T'HH:mm:ss'Z'")), ...
 'multistart_count',height(MT),'multistart_max_scaled_error',max(MT.max_scaled_parameter_error), ...
 'gauge_max_error_W',gaugeerr),PrettyPrint=true));
fprintf('COMPLETE %s\n',run_dir);
end
function [hat,res,flag]=solve_inverse(g0,Y,p,c,B,start,options)
span=diff(B,1,2).';lo=B(:,1).';
[x,res,~,flag]=lsqnonlin(@objective,start,zeros(1,3),ones(1,3),options);hat=lo+x.*span;
 function [r,J]=objective(x)
  [pp,~,J]=pvi_power_model(g0,Y,lo+x.*span,c);r=pp-p;J=J.*span;
 end
end
function [rk,sv,co]=spectrum(J,n)
sv=svd(J,0);sv(end+1:n,1)=0;tol=max(size(J))*eps(max([1;sv]));rk=sum(sv>tol);
co=Inf;if sv(n)>tol,co=sv(1)/sv(n);end
end
function grid=make_grid(B,n)
[m,x,z]=ndgrid(linspace(B(1,1),B(1,2),n),linspace(B(2,1),B(2,2),n),linspace(B(3,1),B(3,2),n));grid=[m(:) x(:) z(:)];
end
function T=metric_summary(M)
names=unique(M.case,'stable');r=cell(numel(names),9);
for j=1:numel(names)
 x=M(M.case==names(j),:);r(j,:)={names(j),height(x),mean(x.mass_error_g),prctile(x.mass_error_g,95), ...
 mean(x.planar_com_error_mm),prctile(x.planar_com_error_mm,95),mean(x.fit_rmse_W),mean(x.bound_hit),sum(x.exitflag<=0)};
end
T=cell2table(r,'VariableNames',{'case','n','mass_mae_g','mass_p95_g','com_mean_mm','com_p95_mm','fit_rmse_mean_W','bound_hit_fraction','nonconverged'});
end
function make_figures(run_dir,T,CT,MS,NS)
set(groot,'defaultAxesFontName','Arial','defaultAxesFontSize',10);
f=figure('Visible','off','Position',[50 50 1000 430]);tiledlayout(1,2,'Padding','compact');
nexttile;x=T(T.pose_set=="probe02_all8",:);scatter(x.mass_kg*1000,x.cx_m*1000,22,x.s3,'filled');colorbar;xlabel('Mass (g)');ylabel('COM x (mm)');title('Fixed 8 poses: scaled minimum singular value');
nexttile;hold on;names=["probe01_all8","probe02_all8","probe03_all8","probe02_fit6"];
for k=1:numel(names),v=sort(T.s3(T.pose_set==names(k)));plot(v,(1:numel(v))/numel(v),'LineWidth',1.5);end
xlabel('Scaled minimum singular value');ylabel('Grid empirical fraction');legend(strrep(names,'_',' '),'Location','southeast');title('Exploratory static information; fixed main probe');grid on;savefigs(f,run_dir,'sensitivity');
f=figure('Visible','off','Position',[50 50 1050 430]);tiledlayout(1,2,'Padding','compact');
nexttile;bar(CT.profiled_s3);xticks(1:height(CT));xticklabels(strrep(CT.case,'_',' '));xtickangle(35);ylabel('Profiled scaled minimum singular value');title('Loss uncertainty removes payload information');
nexttile;bar([CT.ideal_std_mass_g,CT.ideal_std_cx_mm,CT.ideal_std_cz_mm]);set(gca,'YScale','log');ylim([1 2000]);xticks(1:height(CT));xticklabels(strrep(CT.case,'_',' '));xtickangle(35);ylabel('Conditional local ideal SD (g or mm)');legend('m (g)','cx (mm)','cz (mm)','Location','northwest');savefigs(f,run_dir,'calibration_confounding');
f=figure('Visible','off','Position',[50 50 1050 430]);tiledlayout(1,2,'Padding','compact');
nexttile;bar([MS.mass_mae_g MS.com_mean_mm]);xticks(1:height(MS));xticklabels(strrep(MS.case,'_',' '));xtickangle(35);ylabel('Mean absolute mass / COM distance error');legend('Mass (g)','Planar COM (mm)','Location','northwest');title('Static model mismatch; nominal inverse');
nexttile;bar([NS.mass_mae_g NS.com_mean_mm]);xticks(1:height(NS));xticklabels(strrep(NS.case,'_',' '));ylabel('Mean absolute mass / COM distance error');legend('Mass (g)','Planar COM (mm)','Location','northwest');title('Independent Gaussian noise per plateau');savefigs(f,run_dir,'noise_mismatch');
end
function savefigs(f,run_dir,name)
exportgraphics(f,fullfile(run_dir,'figures',[name '.png']),'Resolution',180);exportgraphics(f,fullfile(run_dir,'figures',[name '.pdf']),'ContentType','vector');close(f);
end
function write_text(path,t)
fid=fopen(path,'w','n','UTF-8');assert(fid>0);c=onCleanup(@()fclose(fid));fprintf(fid,'%s\n',t); %#ok<NASGU>
end
