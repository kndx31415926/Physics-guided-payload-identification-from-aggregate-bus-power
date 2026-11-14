function value=payload_pnn_sha256(file)
% Compute the SHA-256 digest of a file.
fid=fopen(file,'rb');assert(fid>=0,'payload:Read','Cannot read %s.',file);
c=onCleanup(@()fclose(fid)); %#ok<NASGU>
digest=java.security.MessageDigest.getInstance('SHA-256');
while ~feof(fid)
    bytes=fread(fid,1024*1024,'*uint8');if ~isempty(bytes),digest.update(bytes);end
end
value=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end
