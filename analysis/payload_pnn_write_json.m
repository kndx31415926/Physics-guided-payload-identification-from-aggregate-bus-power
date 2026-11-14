function payload_pnn_write_json(file,value)
% Write JSON to a new output file.
assert(~isfile(file),'payload:Exists','Refusing to overwrite %s.',file);
fid=fopen(file,'w','n','UTF-8');assert(fid>=0,'payload:Write','Cannot create %s.',file);
cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s\n',jsonencode(value,PrettyPrint=true));
end
