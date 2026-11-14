function info=test_psv_manifest()
% Reject both replacement bytes and altered path/plan identities on resume.
root=fileparts(fileparts(mfilename('fullpath')));addpath(root,fullfile(root,'src'));
folder=fullfile(root,'results',['psv_smoke_manifest_contract_' char(javaMethod('randomUUID','java.util.UUID'))]);mkdir(folder);mkdir(fullfile(folder,'trials'));
plan=struct('manifest',table([1;2],'VariableNames',{'trial_id'}),'plan_signature','fixture-plan');
ledger=psv_raw_manifest('load',folder,plan);assert(isempty(ledger));
value=1;save(fullfile(folder,'trials','trial_000001.mat'),'value');ledger=psv_raw_manifest('append',folder,plan,ledger,1);
first=fileread(fullfile(folder,'raw_record_manifest.csv'));loaded=psv_raw_manifest('load',folder,plan);assert(isequal(loaded,ledger));
value=2;save(fullfile(folder,'trials','trial_000002.mat'),'value');ledger=psv_raw_manifest('append',folder,plan,ledger,2);
assert(ledger.sha256(1)==loaded.sha256(1)&&height(ledger)==2&&contains(fileread(fullfile(folder,'raw_record_manifest.csv')),extractAfter(string(first),newline)));
psv_raw_manifest('load',folder,plan);
value=999;save(fullfile(folder,'trials','trial_000001.mat'),'value');rejected=false;
try,psv_raw_manifest('load',folder,plan);catch e,rejected=strcmp(e.identifier,'psv:RawChanged');end
assert(rejected,'psv:TamperTest','Changed record was not rejected.');
rejected=false;try,psv_raw_manifest('append',folder,plan,ledger,1);catch e,rejected=strcmp(e.identifier,'psv:RawChanged');end
assert(rejected,'psv:TamperTest','Replacement hash was silently accepted.');
info=struct('pass',true,'checks',5,'folder',folder,'scope','Append preserves sealed bytes/hashes; resume and append both reject tampering.');
fprintf('PSV RAW MANIFEST CONTRACT PASS: 5 checks.\n');
end
