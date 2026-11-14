function hash=pnn_model_hash(value,kind)
%PNN_MODEL_HASH SHA256 of an exact MATLAB value or file bytes.
if nargin<2,kind='value';end
md=java.security.MessageDigest.getInstance('SHA-256');
if strcmp(kind,'file')
    fid=fopen(value,'rb');assert(fid>=0,'pnn:Hash','Cannot open %s.',value);
    clean=onCleanup(@()fclose(fid)); %#ok<NASGU>
    while ~feof(fid)
        bytes=fread(fid,1048576,'*uint8');if ~isempty(bytes),md.update(bytes);end
    end
else
    md.update(getByteStreamFromArray(value));
end
hash=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
