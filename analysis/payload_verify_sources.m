function report=payload_verify_sources(sourceTable,snapshot,packageRoot)
% Verify recorded MATLAB files and explicitly mapped distribution changes.
snapshot=canonical(snapshot);packageRoot=canonical(packageRoot);
assert(all(ismember({'relative_path','sha256','bytes'},sourceTable.Properties.VariableNames)), ...
    'payload:SourceManifest','Source manifest columns are incomplete.');
rows=find(endsWith(lower(string(sourceTable.relative_path)),'.m'));
assert(~isempty(rows),'payload:Sources','No MATLAB entries in source manifest.');
mappingFile=fullfile(packageRoot,'provenance','distribution_sources.json');
mapping=struct([]);
if isfile(mappingFile)
    value=jsondecode(fileread(mappingFile));
    if isstruct(value)&&isscalar(value)&&isfield(value,'files'),mapping=value.files;
    elseif isstruct(value)&&isscalar(value)&&isfield(value,'sources'),mapping=value.sources;
    else,mapping=value;end
    assert(isstruct(mapping)||isempty(mapping),'payload:DistributionMap','Invalid source mapping.');
end
mappingPaths=strings(numel(mapping),1);
for j=1:numel(mapping)
    assert(isfield(mapping(j),'relative_path'),'payload:DistributionMap','Mapping lacks relative_path.');
    mappingPaths(j)=normalized(mapping(j).relative_path);
    assert(valid_relative(mappingPaths(j)),'payload:DistributionMap','Mapping path must be package-relative.');
end
assert(numel(unique(mappingPaths))==numel(mappingPaths),'payload:DistributionMap','Duplicate mapping paths.');
verified=0;changed=0;excluded=0;
for k=reshape(rows,1,[])
    relative=normalized(sourceTable.relative_path(k));
    assert(valid_relative(relative),'payload:SourcePath','Source path must be snapshot-relative.');
    file=canonical(fullfile(snapshot,strrep(char(relative),'/',filesep)));
    assert(within(file,snapshot),'payload:SourcePath','Source path escapes the snapshot.');
    recordIndex=[];
    if within(file,packageRoot)
        packageRelative=string(strrep(file(numel(packageRoot)+2:end),'\','/'));
        recordIndex=find(mappingPaths==packageRelative);
    end
    originalHash=char(string(sourceTable.sha256(k)));originalBytes=double(sourceTable.bytes(k));
    assert(valid_hash(originalHash)&&isfinite(originalBytes)&&originalBytes>=0&&fix(originalBytes)==originalBytes, ...
        'payload:SourceManifest','Invalid original source hash or size.');
    if isempty(recordIndex)
        expectedHash=originalHash;expectedBytes=originalBytes;
    else
        m=mapping(recordIndex);
        assert(all(isfield(m,{'original_sha256','original_bytes'}))&& ...
            strcmp(char(string(m.original_sha256)),originalHash)&&double(m.original_bytes)==originalBytes, ...
            'payload:DistributionOrigin','Mapping does not match original source manifest: %s.',relative);
        isExcluded=isfield(m,'excluded')&&isequal(m.excluded,true);
        if isExcluded
            assert(~isempty(regexp(char(relative), ...
                '^scripts/paper_matlab_figures_[^/]+/paper_fig_[^/]+\.m$','once')), ...
                'payload:DistributionExclusion','Only standalone plot helpers may be excluded: %s.',relative);
            assert(~isfile(file)&&~isfolder(file),'payload:DistributionExclusion','Excluded file is still present: %s.',relative);
            excluded=excluded+1;continue
        end
        assert(all(isfield(m,{'distributed_sha256','distributed_bytes'})), ...
            'payload:DistributionMap','Mapping lacks distributed file identity: %s.',relative);
        expectedHash=char(string(m.distributed_sha256));expectedBytes=double(m.distributed_bytes);
        assert(valid_hash(expectedHash)&&isfinite(expectedBytes)&&expectedBytes>=0&&fix(expectedBytes)==expectedBytes, ...
            'payload:DistributionMap','Invalid distributed source hash or size.');
        changed=changed+~strcmp(expectedHash,originalHash);
    end
    assert(isfile(file),'payload:SourceMissing','Missing source %s.',relative);
    info=dir(file);
    assert(isscalar(info)&&info.bytes==expectedBytes&&strcmp(payload_pnn_sha256(file),expectedHash), ...
        'payload:SourceHash','Source differs from recorded identity: %s.',relative);
    verified=verified+1;
end
report=struct('original_matlab_rows',rows,'verified_files',verified, ...
    'mapped_changes',changed,'excluded_plot_helpers',excluded);
end

function value=normalized(value),value=string(strrep(char(string(value)),'\','/'));end
function yes=valid_relative(value)
text=char(value);parts=split(value,'/');
yes=~isempty(text)&&~startsWith(value,'/')&&isempty(regexp(text,'^[A-Za-z]:','once'))&& ...
    ~any(ismember(parts,["",".",".."]))&&~contains(value,char(0));
end
function yes=valid_hash(value),yes=~isempty(regexp(value,'^[0-9a-f]{64}$','once'));end
function value=canonical(value),value=char(java.io.File(char(value)).getCanonicalPath());end
function yes=within(value,parent)
if ispc,value=lower(value);parent=lower(parent);end
yes=strcmp(value,parent)||startsWith(value,[parent filesep]);
end
