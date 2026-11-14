function T=bpil_arm_serial_transport(port_name,H)
%BPIL_ARM_SERIAL_TRANSPORT Bounded nonblocking receive drain, explicit port.
% No reset, mode switch, home, torque write or motion occurs on construction.
% A write completion is a host timestamp, never a device application ACK.
assert((ischar(port_name)||(isstring(port_name)&&isscalar(port_name)))&&strlength(port_name)>0, ...
    'bpil:ArmPort','Select one explicit serial port; automatic probing is disabled.');
report=bpil_arm_preflight(H,[],'inspect');
assert(report.ready,'bpil:ArmTransportProfile','Invalid transport settings.');
timer=tic;closed=false;fault='';buffer=uint8([]);tx_available=0;
port=serialport(char(port_name),H.baud_rate,'Timeout',max(.1,H.request_timeout_s));
T=struct('now',@now_s,'poll',@poll,'write',@send,'wait',@wait_s,'close',@close_port, ...
    'is_mock',false,'clock_id',H.clock_id,'port_name',char(port_name));
    function t=now_s(),t=toc(timer);end
    function check()
        assert(~closed,'bpil:ArmSerialClosed','Serial port is closed.');
        assert(isempty(fault),'bpil:ArmSerialFault','Serial transport fault: %s',fault);
    end
    function frames=poll()
        check();frames={};
        try
            n=double(port.NumBytesAvailable);
            assert(n+numel(buffer)<=H.max_rx_buffer_bytes,'bpil:ArmRxOverflow','Serial receive backlog exceeds bound.');
            n=min(n,H.max_rx_bytes_per_poll);
            if n>0,buffer=[buffer reshape(read(port,n,'uint8'),1,[])];end
            received=now_s();
            while true
                j=find(buffer==10,1);if isempty(j),break;end
                line=buffer(1:j-1);buffer=buffer(j+1:end);
                assert(numel(line)<=H.max_line_bytes,'bpil:ArmFrameSize','Serial frame exceeds bound.');
                assert(numel(frames)<H.max_rx_queue,'bpil:ArmRxOverflow','Too many frames in one drain.');
                if ~isempty(line)&&line(end)==13,line(end)=[];end
                frames{end+1}=struct('raw',native2unicode(line,'UTF-8'),'received_t',received); %#ok<AGROW>
            end
            assert(numel(buffer)<=H.max_line_bytes,'bpil:ArmFrameSize','Unterminated serial frame exceeds bound.');
        catch e
            fault=[e.identifier ': ' e.message];rethrow(e);
        end
    end
    function D=send(packet)
        check();
        try
            assert(ischar(packet)&&isrow(packet)&&~isempty(packet)&&packet(end)==char(10), ...
                'bpil:ArmPacket','Expected one LF-terminated JSON packet.');
            assert(sum(packet==char(10))==1,'bpil:ArmPacket','Only one JSON packet per write is permitted.');
            a=jsondecode(packet);assert(isstruct(a)&&isscalar(a)&&isfield(a,'T')&&any(a.T==[102 105]), ...
                'bpil:ArmPacket','Only position commands and observation requests are supported.');
            bytes=unicode2native(packet,'UTF-8');
            assert(numel(bytes)<=H.max_line_bytes,'bpil:ArmPacket','Oversize outgoing packet.');
            duration=10*numel(bytes)/H.baud_rate;
            start=now_s();wire_start=max(start,tx_available);
            wire_end=wire_start+duration;
            assert(wire_end-start<=H.max_tx_backlog_s,'bpil:ArmTxBacklog','Estimated UART queue exceeds bound; no packet written.');
            write(port,uint8(bytes),'uint8');
            completed=now_s();
            % A slow host write may enqueue its bytes near return. Do not
            % treat the UART as empty merely because the pre-call estimate
            % elapsed while write was blocked. This is a conservative host
            % estimate, not a measurement of the driver/device TX queue.
            guarded_end=max(wire_end,completed+duration);
            D=struct('sent_t',start,'write_completed_t',completed,'acknowledged',false, ...
                'tx_start_estimate',wire_start,'tx_end_estimate',guarded_end, ...
                'byte_count',numel(bytes),'application_time_known',false, ...
                'tx_backlog_measured',false);
            tx_available=guarded_end;
        catch e
            fault=[e.identifier ': ' e.message];rethrow(e);
        end
    end
    function wait_s(dt)
        check();validateattributes(dt,{'numeric'},{'scalar','finite','nonnegative'});
        if dt>0,pause(min(dt,.01));end
    end
    function close_port()
        if closed,return;end
        closed=true;try,delete(port);catch,end
        % Deliberately preserve torque/mode/target. This is not an emergency stop.
    end
end
