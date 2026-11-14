function [packet,info]=bdclp_wire_packet(kind,data,H,mode)
%BDCLP_WIRE_PACKET Pure wire-format serialization and UART 8N1 byte timing.
% Simulation uses explicitly nominal wire coordinates; never send its output.
if nargin<4,mode='simulation';end
assert(any(strcmp(mode,{'simulation','hardware'})),'bdclp:WireMode','Unknown wire mode.');
validateattributes(H.baud_rate,{'numeric'},{'scalar','finite','positive'});
hardware=strcmp(mode,'hardware');
switch kind
    case 'command'
        if hardware
            [packet,info]=bdclp_encode_command(data,H,'hardware');return;
        end
        validateattributes(data.q,{'numeric'},{'real','finite','size',[1 4]});
        validateattributes(data.speed,{'numeric'},{'scalar','integer','>=',1,'<=',4096});
        validateattributes(data.acc,{'numeric'},{'scalar','integer','>=',1,'<=',254});
        wire=H.nominal_sign.*data.q+H.nominal_zero_offset_rad;
        wire=round(wire*1e6)/1e6;
        obj=struct('T',102,'base',wire(1),'shoulder',wire(2), ...
            'elbow',wire(3),'hand',wire(4),'spd',data.speed,'acc',data.acc);
    case 'position_request'
        validateattributes(data.request_id,{'numeric'},{'scalar','integer','>=',0,'<=',2^32-1});
        obj=struct('T',105,'bdclp',1,'rid',data.request_id);
        if isfield(data,'read_limits')&&data.read_limits,obj.lim=1;end
    case 'position_feedback'
        assert(~hardware,'bdclp:WireFeedback','Hardware feedback must come from the device.');
        validateattributes(data.q,{'numeric'},{'real','finite','size',[1 4]});
        validateattributes(data.sample_t,{'numeric'},{'scalar','real','finite','nonnegative'});
        validateattributes(data.seq,{'numeric'},{'scalar','finite','integer','>=',0,'<=',2^32-1});
        validateattributes(data.request_id,{'numeric'},{'scalar','finite','integer','>=',0,'<=',2^32-1});
        wire=H.nominal_sign.*data.q+H.nominal_zero_offset_rad;
        us=mod(round(data.sample_t*1e6),2^32);
        span=0;if isfield(data,'transaction_dt_s'),span=data.transaction_dt_s;end
        validateattributes(span,{'numeric'},{'scalar','real','finite','nonnegative'});
        ends=us;starts=mod(us-round(span*1e6),2^32);
        obj=struct('T',1051,'fver',2,'freq',data.request_id,'fseq',data.seq, ...
            'fmode',1,'b',round(wire(1)*1e6)/1e6,'s',round(wire(2)*1e6)/1e6, ...
            'e',round(wire(3)*1e6)/1e6,'t',round((wire(4)+wire(2)+wire(3)-pi/2)*1e6)/1e6, ...
            'fok',31,'ft0',starts,'ft1',ends);
    case 'wrist_limit'
        validateattributes(data.limit,{'numeric'},{'scalar','integer','>=',1,'<=',1000});
        obj=struct('T',107,'tor',data.limit);
    case 'wrist_mode'
        obj=struct('T',1,'mode',1);
    otherwise
        error('bdclp:WireKind','Unknown packet kind.');
end
packet=[jsonencode(obj) sprintf('\n')];
info=struct('byte_count',numel(unicode2native(packet,'UTF-8')), ...
    'hardware_ready',hardware,'transmitted',false,'mode',mode);
info.tx_lower_bound_s=10*info.byte_count/H.baud_rate;
end
