function H=bpil_arm_write_profile_template(file)
%BPIL_ARM_WRITE_PROFILE_TEMPLATE Save an uncalibrated JSON template, no I/O.
assert((ischar(file)||(isstring(file)&&isscalar(file)))&&strlength(file)>0, ...
    'bpil:ArmProfileFile','Choose a profile JSON filename.');
assert(~isfile(file),'bpil:SessionExists','Do not overwrite an existing local calibration.');
H=bpil_arm_control_profile();
folder=fileparts(file);if ~isempty(folder)&&~isfolder(folder),mkdir(folder);end
jfile=java.io.File(char(file));
assert(jfile.createNewFile(),'bpil:SessionExists','Do not overwrite an existing local calibration.');
fid=fopen(file,'w','n','UTF-8');
assert(fid>=0,'bpil:ArmProfileFile','Could not exclusively create the profile.');
cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s\n',jsonencode(H,PrettyPrint=true));
end
