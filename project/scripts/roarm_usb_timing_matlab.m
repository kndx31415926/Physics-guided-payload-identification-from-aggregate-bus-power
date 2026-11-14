function R = roarm_usb_timing_matlab(outputDirectory, expectedIdentity)
%ROARM_USB_TIMING_MATLAB Read-only stock T105 timing; never sends a target.
% No arguments: preview only, without constructing or opening a serial port.
% Two arguments: execute after an external PowerShell CIM identity check.
% The identity argument records that external declaration; it is not a USB
% identity measurement by MATLAB. This is not the T102 trajectory controller.

stages = struct('name', {'warmup_10hz','baseline_10hz','main_20hz_r1', ...
    'main_20hz_r2','main_20hz_r3','stress_30hz','stress_40hz'}, ...
    'hz', {10,10,20,20,20,30,40}, 'count', {20,100,1200,1200,1200,300,400});
identity = 'USB\VID_10C4&PID_EA60\8E1996E6427FEF119BB0181CEDD322A4';
if nargin == 0
    R = struct('preview',true,'port','COM15','only_packet','{"T":105}\n', ...
        'motion_commands',0,'stages',stages,'nominal_duration_s',212, ...
        'planned_requests',4420,'timeout_s',.100,'single_outstanding_request',true);
    disp(jsonencode(R,'PrettyPrint',true));
    return
end
assert(nargin == 2,'roarm:TimingArguments', ...
    'Supply a new output directory and the externally checked USB identity.');
assert(ischar(outputDirectory) || (isstring(outputDirectory) && isscalar(outputDirectory)), ...
    'roarm:TimingDirectory','Output directory must be one path.');
assert(ischar(expectedIdentity) || (isstring(expectedIdentity) && isscalar(expectedIdentity)), ...
    'roarm:TimingIdentity','Expected identity must be one string.');
outputDirectory = char(outputDirectory);
expectedIdentity = char(expectedIdentity);
assert(isrow(outputDirectory) && ~isempty(outputDirectory), ...
    'roarm:TimingDirectory','Output directory must not be empty.');
assert(strcmp(expectedIdentity,identity),'roarm:TimingIdentity', ...
    'The supplied external identity declaration is not the commissioned USB controller.');
assert(strcmp(version('-release'),'2026a'),'roarm:TimingRelease', ...
    'This benchmark is labelled for MATLAB R2026a; do not silently change its host stack.');
assert(~isfile('C:/new/hardware_stop.flag'),'roarm:TimingStopped','Stop flag is present.');
assert(~isfile(outputDirectory) && ~isfolder(outputDirectory), ...
    'roarm:TimingOverwrite','Output already exists; refusing overwrite.');
[made,msg] = mkdir(outputDirectory);
assert(made,'roarm:TimingDirectory','Cannot create output directory: %s',msg);
sourcePath = [mfilename('fullpath') '.m'];
snapshotPath = fullfile(outputDirectory,'executed_script.m');
[copied,msg] = copyfile(sourcePath,snapshotPath);
assert(copied,'roarm:TimingSnapshot','Cannot snapshot source: %s',msg);
sourceHash = file_sha256(snapshotPath);

clock = tic;
rows = cell(sum([stages.count]),1); rowCount = 0;
raw = cell(sum([stages.count])+100,1); rawCount = 0;
csvCursor = 0; rawCursor = 0; csvFault = false; rawFault = false;
pending = ''; active = []; currentStage = 'startup'; lastTx = NaN;
failure = ''; completedStages = {}; lastCheckpointMs = 0;
serial = []; closed = false;
portGuard = onCleanup(@close_port);
metadata = struct('schema','roarm_readonly_usb_timing_v1', ...
    'utc_started',utc_now(),'port','COM15','device',identity, ...
    'baud',115200,'format','8N1 LF JSON','script_sha256',sourceHash, ...
    'stopwatch_frequency_hz',NaN,'stopwatch_high_resolution',NaN, ...
    'clock_source','MATLAB tic/toc with one shared timer handle', ...
    'powershell_version','','matlab_version',version, ...
    'matlab_release',version('-release'),'os',computer, ...
    'stages',stages,'packet_utf8_bytes',10,'request_timeout_s',.100, ...
    'feedback_age_contract_s',.080, ...
    'scheduling','next start >= previous actual start + period; one outstanding request, no catch-up bursts', ...
    'poll_sleep_ms',1,'wait_function','pause(0.001)', ...
    'source_acquisition_verified',false,'motion_commands_sent',0, ...
    'timing_scope','Host write start to host-observed complete reply; not one-way delay, device sample time, command execution or internal servo period.', ...
    'host_stack','MATLAB R2026a + .NET SerialPort', ...
    'host_loop','read-only T105 polling; no motion/controller execution', ...
    'identity_checked_in_this_function',false, ...
    'identity_verification','External PowerShell CIM check required immediately before invocation; supplied identity is recorded, not independently verified by this function.', ...
    'all_scheduled_samples_retained',true,'checkpoint_every_samples',100, ...
    'checkpoint_delays_included',true,'planned_requests',4420);
write_json(fullfile(outputDirectory,'metadata.json'),metadata);

try
    % Construction does not open the port. Configure control lines first.
    NET.addAssembly('System');
    serial = System.IO.Ports.SerialPort();
    serial.PortName = 'COM15';
    serial.BaudRate = int32(115200);
    serial.Parity = System.IO.Ports.Parity.None;
    serial.DataBits = int32(8);
    serial.StopBits = System.IO.Ports.StopBits.One;
    serial.Handshake = System.IO.Ports.Handshake.None;
    serial.DtrEnable = false;
    serial.RtsEnable = false;
    serial.ReadTimeout = int32(10);
    serial.WriteTimeout = int32(100);
    serial.NewLine = sprintf('\n');
    check_stop();
    serial.Open();
    add_raw('open','DTR=false RTS=false; no reset requested',NaN,toc(clock));
    drainUntil = toc(clock)+1;
    while toc(clock) < drainUntil
        poll_lines(true);
        pause(.001);
    end
    assert(isempty(pending),'roarm:TimingStartupPartial', ...
        'Incomplete startup line; clean stock-response association not established.');
    for stageNumber = 1:numel(stages)
        stage = stages(stageNumber);
        currentStage = stage.name;
        period = 1/stage.hz;
        save_checkpoint('running');
        for requestIndex = 1:stage.count
            check_stop();
            if isnan(lastTx), due = toc(clock); else, due = lastTx+period; end
            while toc(clock) < due
                poll_lines(false);
                pause(.001);
            end
            poll_lines(false);
            assert(isempty(pending),'roarm:TimingPartial', ...
                'Unmatched partial response before next query.');
            active = struct('stage',stage.name,'request_index',requestIndex, ...
                'target_hz',stage.hz,'period_s',period,'due_s',due, ...
                'tx_start_s',NaN,'write_end_s',NaN,'first_byte_s',NaN, ...
                'rx_frame_s',NaN,'parse_end_s',NaN,'response_bytes',NaN, ...
                'status','write_attempted','b',NaN,'s',NaN,'e',NaN,'t',NaN);
            active.tx_start_s = toc(clock);
            lastTx = active.tx_start_s;
            % The literal below is the ONLY outbound packet in this function.
            serial.WriteLine('{"T":105}');
            active.write_end_s = toc(clock);
            deadline = active.tx_start_s+.100;
            while isnan(active.rx_frame_s)
                poll_lines(false);
                if ~isnan(active.rx_frame_s), break; end
                if toc(clock) >= deadline
                    active.status = 'timeout';
                    error('roarm:TimingTimeout', ...
                        'No complete response within 100 ms; stop rather than reuse a late reply.');
                end
                pause(.001);
            end
            if active.rx_frame_s > deadline
                active.status = 'late_over_timeout';
                error('roarm:TimingLate','Reply observed after the 100-ms limit.');
            end
            retain_active();
            if mod(requestIndex,100) == 0, save_checkpoint('running'); end
        end
        completedStages{end+1} = stage.name; %#ok<AGROW>
        save_checkpoint('running');
    end
catch err
    append_failure([err.identifier ': ' err.message]);
    if ~isempty(active)
        if any(strcmp(active.status,{'write_attempted','ok'})), active.status = 'error'; end
        retain_active();
    end
    add_raw('error',failure,NaN,toc(clock));
end
% Close before final file I/O. Neither Close nor Dispose sends a robot packet.
close_port();
if ~isempty(pending)
    add_raw('unparsed_pending_on_exit',pending,NaN,toc(clock));
    pending = '';
end
add_raw('closed','No motion, mode, reset, calibration or torque packet sent',NaN,toc(clock));
try
    if isempty(failure), state = 'complete'; else, state = 'failed'; end
    save_checkpoint(state);
catch err
    append_failure(['Final checkpoint failed: ' err.message]);
end
R = struct('error',error_value(),'completed_stages',{completedStages}, ...
    'observations',rowCount,'motion_commands_sent',0,'output_dir',outputDirectory, ...
    'csv_checkpoint_fault',csvFault,'raw_checkpoint_fault',rawFault, ...
    'source_acquisition_verified',false,'host_stack',metadata.host_stack);
% A separate complete in-memory record also protects against partial append I/O.
try
    recordedRows = rows(1:rowCount); recordedRaw = raw(1:rawCount); %#ok<NASGU>
    save(fullfile(outputDirectory,'session.mat'),'metadata','R','recordedRows','recordedRaw','-v7');
    write_json(fullfile(outputDirectory,'acquisition_summary.json'),R);
catch err
    append_failure(['Final evidence save failed: ' err.message]);
    R.error = failure;
end
clear portGuard
disp(jsonencode(R,'PrettyPrint',true));
if ~isempty(failure), error('roarm:TimingFailed','%s',failure); end

    function check_stop()
        assert(~isfile('C:/new/hardware_stop.flag'),'roarm:TimingStopped', ...
            'Stop flag present; read-only measurement stopped.');
    end

    function poll_lines(startup)
        if serial.BytesToRead <= 0, return; end
        chunk = char(serial.ReadExisting());
        noticed = toc(clock);
        if ~isempty(active) && isnan(active.first_byte_s)
            active.first_byte_s = noticed;
        end
        pending = [pending chunk]; %#ok<AGROW>
        assert(numel(pending) <= 32768,'roarm:TimingOverflow','Receive buffer overflow.');
        while true
            lf = find(pending == char(10),1);
            if isempty(lf), break; end
            lineWithTerminator = pending(1:lf);
            line = pending(1:lf-1);
            while ~isempty(line) && line(end) == char(13), line(end) = []; end
            pending = pending(lf+1:end);
            index = NaN;
            if ~isempty(active), index = active.request_index; end
            add_raw('rx',line,index,noticed);
            assert(isempty(regexpi(line,'status:\s*failed|Servo ID[^\r\n]*failed|rst:|boot:','once')), ...
                'roarm:TimingDeviceText','Device read failure or restart text observed.');
            try, obj = jsondecode(line); catch, continue; end
            if ~isstruct(obj) || ~isscalar(obj) || ~isfield(obj,'T'), continue; end
            if ~isnumeric(obj.T) || ~isscalar(obj.T) || ~isfinite(obj.T), continue; end
            if obj.T == 1005 && isfield(obj,'status') && isscalar(obj.status) && ...
                    (isnumeric(obj.status) || islogical(obj.status)) && obj.status == 0
                error('roarm:TimingServoRead','Device reports servo read failure: %s',line);
            end
            if obj.T ~= 1051, continue; end
            assert(~startup,'roarm:TimingUnsolicited', ...
                'Unsolicited angle streaming found; cannot correlate stock responses.');
            assert(~isempty(active) && isnan(active.rx_frame_s),'roarm:TimingAssociation', ...
                'Extra angle frame; stock request association is ambiguous.');
            for fieldName = {'b','s','e','t','x','y','z'}
                key = fieldName{1};
                assert(isfield(obj,key) && isnumeric(obj.(key)) && ...
                    isreal(obj.(key)) && isscalar(obj.(key)) && isfinite(obj.(key)), ...
                    'roarm:TimingNumeric','Invalid angle/position field %s.',key);
            end
            active.rx_frame_s = noticed;
            active.response_bytes = numel(unicode2native(lineWithTerminator,'UTF-8'));
            for fieldName = {'b','s','e','t'}
                key = fieldName{1}; active.(key) = double(obj.(key));
            end
            active.parse_end_s = toc(clock);
            active.status = 'ok';
        end
    end

    function retain_active()
        rowCount = rowCount+1;
        rows{rowCount} = active;
        active = [];
    end

    function add_raw(kind,text,index,at)
        rawCount = rawCount+1;
        raw{rawCount} = struct('elapsed_s',at,'stage',currentStage, ...
            'request_index',index,'kind',kind,'raw',text);
    end

    function save_checkpoint(state)
        before = toc(clock);
        if rowCount > csvCursor && ~csvFault
            try
                append_csv(fullfile(outputDirectory,'samples.csv'), ...
                    rows(csvCursor+1:rowCount),csvCursor == 0);
                csvCursor = rowCount;
            catch err
                csvFault = true;
                rethrow(err);
            end
        end
        if rawCount > rawCursor && ~rawFault
            try
                append_jsonl(fullfile(outputDirectory,'serial.jsonl'),raw(rawCursor+1:rawCount));
                rawCursor = rawCount;
            catch err
                rawFault = true;
                rethrow(err);
            end
        end
        lastCheckpointMs = 1000*(toc(clock)-before);
        S = struct('state',state,'stage',currentStage,'samples',rowCount, ...
            'elapsed_s',toc(clock),'completed_stages',{completedStages}, ...
            'error',error_value(),'last_checkpoint_ms',lastCheckpointMs, ...
            'motion_commands_sent',0,'output_dir',outputDirectory, ...
            'csv_checkpoint_fault',csvFault,'raw_checkpoint_fault',rawFault);
        write_json(fullfile(outputDirectory,'status.json'),S);
    end

    function value = error_value()
        if isempty(failure), value = NaN; else, value = failure; end
    end

    function append_failure(message)
        if isempty(failure), failure = message; else, failure = [failure ' | ' message]; end
    end

    function close_port()
        if closed, return; end
        closed = true;
        if isempty(serial), return; end
        try
            if serial.IsOpen, serial.Close(); end
        catch err
            append_failure(['Port close error: ' err.message]);
        end
        try, serial.Dispose(); catch err, append_failure(['Port dispose error: ' err.message]); end
    end
end

function append_csv(path,batch,includeHeader)
fields = {'stage','request_index','target_hz','period_s','due_s','tx_start_s', ...
    'write_end_s','first_byte_s','rx_frame_s','parse_end_s','response_bytes', ...
    'status','b','s','e','t'};
lines = cell(numel(batch)+double(includeHeader),1); cursor = 0;
if includeHeader
    cursor = 1; lines{cursor} = ['"' strjoin(fields,'","') '"'];
end
for k = 1:numel(batch)
    values = cell(1,numel(fields));
    for j = 1:numel(fields)
        value = batch{k}.(fields{j});
        if isnumeric(value)
            if isnan(value), text = ''; else, text = sprintf('%.17g',value); end
        else, text = char(value);
        end
        values{j} = ['"' strrep(text,'"','""') '"'];
    end
    cursor = cursor+1; lines{cursor} = strjoin(values,',');
end
append_utf8(path,[strjoin(lines,sprintf('\n')) sprintf('\n')]);
end

function append_jsonl(path,batch)
lines = cell(size(batch));
for k = 1:numel(batch), lines{k} = jsonencode(batch{k}); end
append_utf8(path,[strjoin(lines,sprintf('\n')) sprintf('\n')]);
end

function append_utf8(path,text)
[fid,msg] = fopen(path,'a','n','UTF-8');
assert(fid >= 0,'roarm:TimingOutput','Cannot append %s: %s',path,msg);
guard = onCleanup(@()fclose(fid));
fprintf(fid,'%s',text);
[message,number] = ferror(fid);
assert(number == 0,'roarm:TimingOutput','Append failed for %s: %s',path,message);
clear guard
end

function write_json(path,value)
[fid,msg] = fopen(path,'w','n','UTF-8');
assert(fid >= 0,'roarm:TimingOutput','Cannot write %s: %s',path,msg);
guard = onCleanup(@()fclose(fid));
fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
[message,number] = ferror(fid);
assert(number == 0,'roarm:TimingOutput','Write failed for %s: %s',path,message);
clear guard
end

function value = utc_now()
value = char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));
end

function value = file_sha256(path)
fid = fopen(path,'rb');
assert(fid >= 0,'roarm:TimingHash','Cannot read source snapshot.');
guard = onCleanup(@()fclose(fid));
digest = java.security.MessageDigest.getInstance('SHA-256');
while ~feof(fid), digest.update(fread(fid,1024*1024,'*uint8')); end
value = lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
clear guard
end
