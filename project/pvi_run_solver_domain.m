function result=pvi_run_solver_domain(run_dir)
%PVI_RUN_SOLVER_DOMAIN Additional immutable rank cover for solver bounds.
% No servo simulation, fitting, network change or old-result modification.
root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
if nargin<1,run_dir=fullfile(root,'results','pvi_solver_domain_20261030_v2');end
assert(~isfolder(run_dir),'pvi:Immutable','Choose a fresh output directory.');
mkdir(run_dir);mkdir(fullfile(run_dir,'source'));
diary(fullfile(run_dir,'run.log'));dc=onCleanup(@()diary('off')); %#ok<NASGU>
configfile=fullfile(root,'results','pgar_nominal_20261029_v1','configuration.mat');
C=load(configfile,'cfg');cfg=C.cfg;B=cfg.ident.bounds;
assert(isequal(B,[.06 .25;.04 .20;-.025 .025]),'pvi:Bounds','Unexpected frozen solver bounds.');
% The interval product implementation assumes m>0, cx>=0 and cz straddles 0.
assert(B(1,1)>0&&B(2,1)>=0&&B(3,1)<=0&&B(3,2)>=0);
spec=struct('schema','pvi_solver_domain_cover_v1','payload_bounds',B, ...
 'experiment_bounds',[.08 .22;.05 .19;-.018 .018],'max_nodes_per_set',200000, ...
 'source_config_sha256',prc_file_hash(configfile), ...
 'scope','Known fixed nominal geometry, empty gravity and electrical coefficients; double-precision conservative cover, not interval-arithmetic proof.', ...
 'created_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')));
names={'pvi_run_solver_domain.m','src/pvi_rank_bound.m','src/pvi_power_model.m', ...
 'src/bpil_static_design.m','src/bpil_probe_library.m','src/bpil_make_plant.m','src/prc_file_hash.m'};
vendor=dir(fullfile(root,'vendor','bdcl_v29','*.m'));
for k=1:numel(vendor),names{end+1}=['vendor/bdcl_v29/' vendor(k).name];end %#ok<AGROW>
relative_path=strings(numel(names),1);sha256=relative_path;
for k=1:numel(names)
 relative_path(k)=string(names{k});sha256(k)=string(prc_file_hash(fullfile(root,names{k})));
 destination=fullfile(run_dir,'source',names{k});
 if ~isfolder(fileparts(destination)),mkdir(fileparts(destination));end
 copyfile(fullfile(root,names{k}),destination);
end
writetable(table(relative_path,sha256),fullfile(run_dir,'source_manifest.csv'));
copyfile(configfile,fullfile(run_dir,'nominal_configuration.mat'));
P=bpil_probe_library(cfg);q=P(2).poses;[g0,Y]=bpil_static_design(cfg,q);
coeff=cfg.legacy.power.coefficients(:).';
save(fullfile(run_dir,'numerical_inputs.mat'),'spec','q','g0','Y','coeff','B');
write_text(fullfile(run_dir,'spec.json'),jsonencode(spec,PrettyPrint=true));
sets={'probe02_fit6','probe02_all8'};indices={2:7,1:8};result=struct();rows=cell(2,9);
for k=1:2
 ix=indices{k};timer=tic;
 item=pvi_rank_bound(g0(ix,:),Y(ix,:,:),coeff,B,spec.max_nodes_per_set);
 item.elapsed_s=toc(timer);item.theta_bounds=B;item.pose_indices=ix;
 result.(sets{k})=item;
 rows(k,:)={string(sets{k}),item.continuous_domain_covered,item.certified_boxes, ...
  item.visited_nodes,item.unresolved_boxes,item.max_bisection_depth, ...
  item.uniform_scaled_singular_lower_bound,item.min_lower_bound_over_roundoff_margin,item.elapsed_s};
 fprintf('%s: %s\n',sets{k},jsonencode(item));
end
T=cell2table(rows,'VariableNames',{'pose_set','continuous_domain_covered','certified_boxes', ...
 'visited_nodes','unresolved_boxes','max_bisection_depth','uniform_scaled_singular_lower_bound', ...
 'min_lower_bound_over_roundoff_margin','elapsed_s'});
writetable(T,fullfile(run_dir,'summary.csv'));
write_text(fullfile(run_dir,'continuous_rank_bound.json'),jsonencode(result,PrettyPrint=true));
save(fullfile(run_dir,'results.mat'),'result','T','spec');
for k=1:numel(names)
 assert(strcmp(prc_file_hash(fullfile(root,names{k})),sha256(k)),'pvi:SourceChanged','Source changed during calculation.');
end
assert(strcmp(prc_file_hash(configfile),spec.source_config_sha256),'pvi:ConfigChanged','Configuration changed.');
write_text(fullfile(run_dir,'README.txt'),sprintf([ ...
 'Supplement to pvi_static_20261030_v2; old results untouched.\n', ...
 'Domain is the frozen teacher optimizer box, not merely the training/test box.\n', ...
 'The continuous-cover argument uses the same quadratic midpoint identity and convex beta domain as the original PVI analysis.\n', ...
 'Floating-point sufficient bounds only; no directed outward rounding.\n', ...
 'Conditional injectivity of noiseless F does not prove a unique least-squares minimizer for noisy/mismatched data or optimizer convergence.\n', ...
 'Self-contained numerical replay: addpath(fullfile(run_dir,''source'',''src'')); load(fullfile(run_dir,''numerical_inputs.mat''));\n', ...
 'r6=pvi_rank_bound(g0(2:7,:),Y(2:7,:,:),coeff,B,200000); r8=pvi_rank_bound(g0,Y,coeff,B,200000);\n']));
write_text(fullfile(run_dir,'COMPLETE.json'),jsonencode(struct('completed_utc', ...
 char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')), ...
 'source_verified',true,'scope',spec.scope),PrettyPrint=true));
end
function write_text(path,value)
fid=fopen(path,'w','n','UTF-8');assert(fid>=0);cl=onCleanup(@()fclose(fid));fprintf(fid,'%s\n',value); %#ok<NASGU>
end
