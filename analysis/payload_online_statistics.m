function report = payload_online_statistics(packageRoot, outputDirectory)
%PAYLOAD_ONLINE_STATISTICS Compute paired-stream adaptation statistics.
% Uses recorded predictions, costs, events and configurations with each
% scenario's summarizer. Writes numeric results and diagnostic plots to a
% new output directory and compares them with the saved numerical summaries.

packageRoot=canonical(packageRoot); outputDirectory=canonical(outputDirectory);
assert(isfolder(packageRoot),'payload:Package','Missing package root.');
for name=["studies","data","project","analysis","docs","provenance"]
    assert(~sameOrBelow(outputDirectory,canonical(fullfile(packageRoot,name))), ...
        'payload:Output','Choose an output folder outside the supplied input trees.');
end
if isfolder(outputDirectory)
    q=dir(outputDirectory);
    assert(all(ismember({q.name},{'.','..'})),'payload:Output','Output folder must be new or empty.');
else
    assert(~isfile(outputDirectory),'payload:Output','Output path is a file.');
    mkdir(outputDirectory);
end
oldPath=path; oldFolder=pwd; oldRng=rng;
environment=onCleanup(@()restoreEnvironment(oldPath,oldFolder,oldRng)); %#ok<NASGU>
studies={'pcu_prospective_20261030_v1','pcr_online_ridge_20261031_v4'};
summarizers={'pcu_summarize_online','pcr_summarize_online'};
variants={'pcu_variants','pcr_variants'};
inputs={'configuration.mat','online_predictions.csv','retention_predictions.csv', ...
    'reference_cost_by_block.csv','online_audit.mat'};
tables=tableRegistry(); comparisons=struct([]); panels=struct([]); identities=struct([]);
for s=1:2
    study=studies{s}; source=fullfile(packageRoot,'studies',study);
    snapshot=fullfile(source,'source_snapshot'); work=fullfile(outputDirectory,study);
    sourceManifest=fullfile(source,'source_manifest.csv');
    if isfile(sourceManifest)
        sourceTable=payload_pnn_read_csv(sourceManifest,'source_manifest');
        payload_verify_sources(sourceTable,snapshot,packageRoot);
    end
    mkdir(work); originals=fullfile(work,'original_statistics'); mkdir(originals);
    files=[inputs,reshape({tables.file},1,[])];
    dependencies={fullfile('source_snapshot','src',[summarizers{s} '.m']), ...
        fullfile('source_snapshot','src',[variants{s} '.m']), ...
        fullfile('source_snapshot','src','prc_write_json.m')};
    fileList=unique([files,dependencies],'stable');
    before=cell(numel(fileList),1);
    for k=1:numel(fileList)
        f=fullfile(source,fileList{k}); assert(isfile(f),'payload:Input','Missing %s.',f);
        before{k}=sha256(f);
    end
    for k=1:numel(inputs), copyfile(fullfile(source,inputs{k}),fullfile(work,inputs{k})); end
    for k=1:numel(tables), copyfile(fullfile(source,tables(k).file),fullfile(originals,tables(k).file)); end
    C=load(fullfile(work,'configuration.mat'),'spec'); spec=C.spec;
    assert(isfield(spec,'stream_seeds')&&numel(spec.stream_seeds)==8&& ...
        isfield(spec,'bootstrap_repeats')&&spec.bootstrap_repeats==4000&& ...
        isfield(spec,'blocks')&&spec.blocks==4, ...
        'payload:Protocol','Unexpected archived online protocol.');

    % The original current directory may contain identically named functions.
    % Use only MATLAB defaults and this study's frozen source for each call.
    restoredefaultpath;
    addpath(snapshot,fullfile(snapshot,'src'),fullfile(snapshot,'vendor','bdcl_v29'),'-begin');
    cd(snapshot);
    clear pcu_summarize_online pcr_summarize_online pcu_variants pcr_variants prc_write_json
    for k=1:numel(dependencies)
        [~,functionName]=fileparts(dependencies{k});
        assert(strcmpi(canonical(which(functionName)),canonical(fullfile(source,dependencies{k}))), ...
            'payload:FunctionPath','A frozen summarizer dependency is shadowed: %s.',functionName);
    end
    info=feval(summarizers{s},work,spec);
    assert(info.independent_streams_per_scenario==8&&info.fixed_drift_laws==4, ...
        'payload:Unit','Unexpected statistical units.');
    cd(oldFolder); path(oldPath);

    for k=1:numel(tables)
        A=readtable(fullfile(originals,tables(k).file),'TextType','string','VariableNamingRule','preserve');
        B=readtable(fullfile(work,tables(k).file),'TextType','string','VariableNamingRule','preserve');
        rows=compareTables(A,B,tables(k).keys,study,tables(k).file);
        if isempty(comparisons),comparisons=rows;else,comparisons=[comparisons;rows];end %#ok<AGROW>
    end
    for k=1:numel(fileList)
        f=fullfile(source,fileList{k}); after=sha256(f);
        assert(strcmp(before{k},after),'payload:SourceChanged','Original input changed: %s.',f);
        row=struct('study',study,'relative_path',strrep(fileList{k},'\','/'), ...
            'sha256',before{k},'unchanged_after_recomputation',true);
        if isempty(identities),identities=row;else,identities(end+1,1)=row;end %#ok<AGROW>
    end
    panel=struct('study',study,'summarizer',summarizers{s}, ...
        'bootstrap_seed',spec.bootstrap_seed,'bootstrap_repeats',spec.bootstrap_repeats, ...
        'independent_streams_per_law',numel(spec.stream_seeds), ...
        'evaluation_episodes',info.evaluation_episodes,'prediction_rows',info.prediction_rows, ...
        'regenerated_tables',numel(tables),'result',info);
    if isempty(panels),panels=panel;else,panels(end+1,1)=panel;end %#ok<AGROW>
end
C=struct2table(comparisons); writetable(C,fullfile(outputDirectory,'online_statistics_comparisons.csv'));
report=struct('schema','payload_online_statistics_v1','matlab_version',version, ...
    'panels',panels,'source_identity',identities,'compared_columns',height(C), ...
    'failed_columns',sum(~C.passed),'all_passed',all(C.passed), ...
    'scope','Paired-stream statistics from saved predictions, costs and adaptation records.', ...
    'statistical_unit','Whole independent object/noise stream; eight streams per drift law; all methods and raw/common_clip variants.', ...
    'interval_scope','4000-draw paired whole-stream percentile bootstrap with recorded seeds and comparison order; descriptive intervals without multiplicity correction.', ...
    'tolerance','Identities, flags and counts exact; other numeric values use 1e-8 + 1e-10*abs(original) in their reported units, allowing decimal CSV rounding.', ...
    'preservation','Input hashes are checked before and after processing; reference summaries are copied into original_statistics/.');
writeJson(fullfile(outputDirectory,'online_statistics_report.json'),report);
fprintf('Online statistics: %d table columns compared; %d outside tolerance.\n',height(C),sum(~C.passed));
assert(report.all_passed,'payload:Difference','Inspect online_statistics_comparisons.csv for differences.');
end

function T=tableRegistry()
T=struct('file',{},'keys',{});
T(end+1)=item('online_block_summary.csv',{'scenario','stream_seed','block','method','postprocessing'});
T(end+1)=item('online_stream_summary.csv',{'scenario','stream_seed','method','postprocessing'});
T(end+1)=item('online_pooled_summary.csv',{'scenario','method','postprocessing'});
T(end+1)=item('retention_summary.csv',{'scenario','stream_seed','method','postprocessing'});
T(end+1)=item('terminal_block_summary.csv',{'scenario','method','postprocessing'});
T(end+1)=item('online_paired_stream_deltas.csv',{'scenario','stream_seed','method','control','postprocessing'});
T(end+1)=item('paired_stream_bootstrap.csv',{'scenario','method','control','postprocessing','metric'});
T(end+1)=item('paired_statistics.csv',{'scenario','method','control','postprocessing','metric'});
T(end+1)=item('online_updates.csv',{'scenario','stream_seed','block','method'});
T(end+1)=item('reference_cost_summary.csv',{'scenario','stream_seed','method'});
end
function x=item(file,keys),x=struct('file',file,'keys',{keys});end

function rows=compareTables(A,B,keys,study,file)
assert(isequal(A.Properties.VariableNames,B.Properties.VariableNames)&&height(A)==height(B), ...
    'payload:Schema','Table schema/row count differs: %s / %s.',study,file);
ak=keyString(A,keys);bk=keyString(B,keys);
assert(numel(unique(ak))==height(A)&&numel(unique(bk))==height(B), ...
    'payload:Duplicate','Duplicate statistical unit in %s.',file);
[found,order]=ismember(ak,bk);
assert(all(found),'payload:Pairing','Recomputed table has different identities: %s.',file);
B=B(order,:);rows=struct([]);
for i=1:width(A)
    name=A.Properties.VariableNames{i};x=A.(name);y=B.(name);
    absoluteTolerance=0;relativeTolerance=0;difference=0;
    if (isnumeric(x)||islogical(x))&&(isnumeric(y)||islogical(y))
        x=double(x);y=double(y);
        exact=ismember(name,keys)||islogical(A.(name))||isCountOrFlag(name);
        if ~exact,absoluteTolerance=1e-8;relativeTolerance=1e-10;end
        finite=isfinite(x)&isfinite(y);d=abs(x-y);
        sameMissing=(isnan(x)&isnan(y))|(isinf(x)&isinf(y)&x==y);
        ok=sameMissing|(finite&d<=absoluteTolerance+relativeTolerance*abs(x));
        if any(finite),difference=max(d(finite));else,difference=NaN;end
    else
        x=string(x);y=string(y);ok=(ismissing(x)&ismissing(y))|(~ismissing(x)&~ismissing(y)&x==y);
        difference=double(any(~ok));
    end
    row=struct('study',string(study),'table_file',string(file),'column',string(name), ...
        'rows',height(A),'max_absolute_difference',difference, ...
        'absolute_tolerance',absoluteTolerance,'relative_tolerance',relativeTolerance, ...
        'failed_rows',sum(~ok),'passed',all(ok));
    if isempty(rows),rows=row;else,rows(end+1,1)=row;end %#ok<AGROW>
end
end

function tf=isCountOrFlag(name)
tf=endsWith(name,{'_n','_count','_events','_observations','_labels','_updates', ...
    '_opportunities','_failures'})||ismember(name,{'bootstrap_repeats','finite_all_streams', ...
    'deployed','eta_changed','network_changed','rollback_preserved', ...
    'has_following_unknown_block','unknown_truth_used'});
end
function k=keyString(T,names)
assert(all(ismember(names,T.Properties.VariableNames)),'payload:Schema','Missing identity column.');
k=repmat("",height(T),1);
for i=1:numel(names)
    x=string(T.(names{i}));assert(~any(ismissing(x)|contains(x,'|')),'payload:Identity','Invalid identity.');
    k=k+"|"+string(names{i})+"="+x;
end
end
function p=canonical(p),p=char(java.io.File(char(p)).getCanonicalPath());end
function yes=sameOrBelow(p,base)
if ispc,p=lower(p);base=lower(base);end
yes=strcmp(p,base)||startsWith(p,[base filesep]);
end
function restoreEnvironment(p,f,r),cd(f);path(p);rng(r);end
function h=sha256(file)
fid=fopen(file,'rb');assert(fid>=0,'payload:Read','Cannot read %s.',file);
cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
md=java.security.MessageDigest.getInstance('SHA-256');
while true
    bytes=fread(fid,1024*1024,'*uint8');if isempty(bytes),break,end
    md.update(typecast(bytes,'int8'));
end
h=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
function writeJson(file,value)
fid=fopen(file,'w','n','UTF-8');assert(fid>=0,'payload:Write','Cannot create report.');
cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
