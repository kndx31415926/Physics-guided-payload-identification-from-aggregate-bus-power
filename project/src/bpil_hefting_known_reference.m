function ref=bpil_hefting_known_reference(file,role,known_theta)
% Explicit independent labels attached to immutable captured reference files.
% Never infer a known label from the network estimate stored in the session.
assert(ismember(string(role),["reference_train","reference_validation"]),'bpil:ReferenceRole','Choose an explicit reference training/validation role.');
validateattributes(known_theta,{'numeric'},{'real','finite','numel',3});
assert(known_theta(1)>0,'bpil:ReferenceMass','Known reference mass must be positive.');
S=load(file,'session_result');R=S.session_result;
assert(strcmp(R.schema,'bpil_hefting_session_result_v1')&&R.completed&&R.obs.acquisition_valid&&all(R.obs.stationary), ...
    'bpil:ReferenceCapture','A complete measured stationary reference capture is required.');
jfile=javaObject('java.io.File',file);
ref=struct('obs',R.obs,'known_theta',reshape(double(known_theta),1,3),'is_reference',true, ...
    'role',char(role),'record_key',char(jfile.getCanonicalPath()), ...
    'record_hash',prc_file_hash(file),'label_source','explicit_independently_known_reference', ...
    'capture_is_mock',R.session.is_mock);
end
