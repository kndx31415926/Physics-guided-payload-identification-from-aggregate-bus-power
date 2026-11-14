function directory=payload_pnn_output_dir(packageRoot,directory,label)
% Create a new output directory outside the supplied data and source trees.
if nargin<3,label='pnn';end
if nargin<2||isempty(directory)
    directory=fullfile(packageRoot,'outputs',[label '_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
end
directory=char(java.io.File(char(directory)).getCanonicalPath());
for item={'studies','data','analysis','project','provenance','docs'}
    protected=char(java.io.File(fullfile(packageRoot,item{1})).getCanonicalPath());
    assert(~strcmpi(directory,protected)&&~startsWith(lower(directory),[lower(protected) filesep]), ...
        'payload:SourceWrite','Outputs must be outside the packaged study, data and source directories.');
end
assert(~isfolder(directory)&&~isfile(directory),'payload:Exists','Choose a new output directory: %s.',directory);
[ok,msg]=mkdir(directory);assert(ok,'payload:Output','%s',msg);
end
