function ledger=psv_raw_manifest(action,run_dir,plan,ledger,ids)
% Append-only identity ledger. Previously sealed hashes are never refreshed.
file=fullfile(run_dir,'raw_record_manifest.csv');folder=fullfile(run_dir,'trials');
if strcmp(action,'load')
    if isfile(file),ledger=readtable(file,'TextType','string','Delimiter',',','VariableNamingRule','preserve');
    else,ledger=table(zeros(0,1),strings(0,1),strings(0,1),strings(0,1),'VariableNames',{'trial_id','record_path','sha256','plan_signature'});end
    assert(all(ismember({'trial_id','record_path','sha256','plan_signature'},ledger.Properties.VariableNames)), 'psv:ManifestSchema','Incomplete raw ledger.');
    assert(numel(unique(ledger.trial_id))==height(ledger)&&all(ismember(ledger.trial_id,plan.manifest.trial_id)), 'psv:ManifestIdentity','Unexpected or duplicate trial IDs.');
    for k=1:height(ledger)
        expected=string(fullfile(folder,sprintf('trial_%06d.mat',ledger.trial_id(k))));
        assert(strcmpi(ledger.record_path(k),expected)&&ledger.plan_signature(k)==string(plan.plan_signature), 'psv:ManifestIdentity','Raw path or plan identity changed.');
        assert(isfile(expected)&&strcmp(prc_file_hash(expected),ledger.sha256(k)), 'psv:RawChanged','Previously sealed raw record changed: %s',expected);
    end
elseif strcmp(action,'append')
    changed=false;
    for id=ids(:).'
        assert(ismember(id,plan.manifest.trial_id),'psv:ManifestIdentity','Unplanned trial.');
        path=string(fullfile(folder,sprintf('trial_%06d.mat',id)));hash=string(prc_file_hash(path));at=find(ledger.trial_id==id);
        if ~isempty(at)
            assert(isscalar(at)&&ledger.record_path(at)==path&&ledger.sha256(at)==hash&&ledger.plan_signature(at)==string(plan.plan_signature), ...
                'psv:RawChanged','Attempted replacement of a sealed raw record.');
        else
            ledger=[ledger;table(id,path,hash,string(plan.plan_signature),'VariableNames',ledger.Properties.VariableNames)]; %#ok<AGROW>
            changed=true;
        end
    end
    if ~changed,return,end
    ledger=sortrows(ledger,'trial_id');temporary=fullfile(run_dir,['raw_manifest_' char(javaMethod('randomUUID','java.util.UUID')) '.csv']);
    writetable(ledger,temporary);[ok,message]=movefile(temporary,file,'f');assert(ok,'psv:ManifestSave','%s',message);
else,error('psv:ManifestAction','Unknown manifest action.');end
end
