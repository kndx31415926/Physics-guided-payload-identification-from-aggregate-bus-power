function T=payload_pnn_read_csv(file,schema)
% Import known CSV schemas with explicit column types.
switch char(schema)
    case 'input_manifest'
        names={'input_path','sha256'};textColumns=1:2;
    case 'source_manifest'
        names={'relative_path','sha256','bytes'};textColumns=1:2;
    case 'predictions'
        names={'trial_id','object_id','condition','method','postprocessing', ...
            'true_mass_kg','true_cx_m','true_cz_m','mass_kg','cx_m','cz_m', ...
            'finite','accepted','bounds_hit','mass_abs_error_g','planar_com_distance_mm'};
        textColumns=3:5;
    case 'summary'
        names={'method','condition','postprocessing','planned_n','finite_n','accepted_n','failed_n','clipped_n', ...
            'finite_coverage','accepted_coverage','mass_mae_g','mass_rmse_g','mass_p95_g','mass_max_g', ...
            'planar_com_mean_distance_mm','planar_com_p95_distance_mm','planar_com_max_distance_mm', ...
            'accepted_mass_mae_g','accepted_planar_com_mean_distance_mm'};
        textColumns=1:3;
    case 'paired_intervals'
        names={'method','baseline','condition','postprocessing','metric','planned_n','paired_n','delta_mean', ...
            'ci95_lower','ci95_upper','primary_method','bonferroni8_one_sided95_upper','bootstrap_replicates', ...
            'bonferroni24_one_sided95_upper','accepted_n','baseline_accepted_n','all_planned_pairs_finite'};
        textColumns=1:5;
    otherwise,error('payload:CSVSchema','Unknown CSV schema %s.',schema);
end
fid=fopen(file,'r','n','UTF-8');assert(fid>=0,'payload:Read','Cannot read %s.',file);
cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
header=fgetl(fid);assert(ischar(header),'payload:CSVHeader','Empty CSV: %s.',file);
header=erase(header,char(65279));
assert(isequal(strsplit(strtrim(header),','),names),'payload:CSVHeader','Unexpected CSV header: %s.',file);
types=repmat({'double'},1,numel(names));types(textColumns)=repmat({'string'},1,numel(textColumns));
options=delimitedTextImportOptions('NumVariables',numel(names));
options.DataLines=[2 Inf];options.Delimiter=',';options.VariableNames=names;
options.VariableTypes=types;options.Encoding='UTF-8';
options.ExtraColumnsRule='error';options.EmptyLineRule='skip';
T=readtable(file,options);
assert(isequal(T.Properties.VariableNames,names),'payload:CSVHeader','Imported column identity differs.');
end
