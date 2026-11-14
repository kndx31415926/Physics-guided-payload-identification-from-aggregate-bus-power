function prc_write_json(path,value)
% Atomic human-readable status record.
temp=[char(path) '.tmp'];fid=fopen(temp,'w','n','UTF-8');assert(fid>=0);
c=onCleanup(@()fclose(fid));fprintf(fid,'%s\n',jsonencode(value,PrettyPrint=true));clear c
movefile(temp,path,'f');
end
