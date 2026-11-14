function [packet, info] = bdclp_encode_command(cmd, H, mode)
%BDCLP_ENCODE_COMMAND Encode a calibrated raw T102 packet, never transmit it.
% mode='hardware' is the default and requires a calibrated mapping. Explicit
% mode='simulation' emits a non-wire JSON object without T, so it cannot be
% mistaken for a calibrated arm command. Speed/acc are motion parameters,
% not independent velocity/acceleration feedforward channels.
if nargin < 3, mode = 'hardware'; end
if nargin < 2, H = bdclp_interface_defaults(); end
validateattributes(cmd.q, {'numeric'}, {'real','finite','size',[1 4]});
validateattributes(cmd.speed, {'numeric'}, {'scalar','real','finite','integer','>=',1,'<=',4096});
validateattributes(cmd.acc, {'numeric'}, {'scalar','real','finite','integer','>=',1,'<=',254});
if strcmp(mode,'simulation')
    obj = struct('schema','bdclp_simulation_command_v1','q',cmd.q, ...
        'speed',cmd.speed,'acc',cmd.acc);
    info = struct('hardware_ready',false,'mode','simulation','wire_q',[]);
elseif strcmp(mode,'hardware')
    local_mapping(H);
    if any(cmd.q < H.model_qmin_rad) || any(cmd.q > H.model_qmax_rad)
        error('bdclp:CommandRange','Model position is outside calibrated joint limits.');
    end
    wire = H.sign .* cmd.q + H.zero_offset_rad;
    if any(wire < H.wire_qmin_rad) || any(wire > H.wire_qmax_rad)
        error('bdclp:WireRange','Mapped position is outside calibrated wire limits.');
    end
    wire=round(wire*1e6)/1e6; % wire precision well below 12-bit encoder step
    if any(wire<H.wire_qmin_rad)||any(wire>H.wire_qmax_rad)
        error('bdclp:WireRange','Rounded wire position is outside calibrated limits.');
    end
    obj = struct('T',102,'base',wire(1),'shoulder',wire(2), ...
        'elbow',wire(3),'hand',wire(4),'spd',cmd.speed,'acc',cmd.acc);
    info = struct('hardware_ready',true,'mode','hardware','wire_q',wire);
else
    error('bdclp:InterfaceMode','Mode must be hardware or simulation.');
end
packet = [jsonencode(obj) sprintf('\n')];
info.byte_count = numel(unicode2native(packet,'UTF-8'));
info.tx_lower_bound_s = info.byte_count * 10 / H.baud_rate; % UART 8N1
info.transmitted = false;
end

function local_mapping(H)
if H.simulation_only || ~H.calibrated || isempty(H.calibration_id) || isempty(H.firmware_id)
    error('bdclp:UncalibratedInterface', ...
        'Hardware encoding requires calibrated joint mapping, limits and identified firmware.');
end
for name = {'sign','zero_offset_rad','model_qmin_rad','model_qmax_rad','wire_qmin_rad','wire_qmax_rad'}
    validateattributes(H.(name{1}),{'numeric'},{'real','finite','size',[1 4]});
end
if any(abs(H.sign) ~= 1) || any(H.model_qmin_rad >= H.model_qmax_rad) || any(H.wire_qmin_rad >= H.wire_qmax_rad)
    error('bdclp:InterfaceMapping','Mapping requires signs +/-1 and ordered finite joint limits.');
end
if ~any(strcmp(H.ee_mode,{'wrist','gripper'}))
    error('bdclp:InterfaceMapping','Confirm wrist or gripper mode before encoding.');
end
validateattributes(H.baud_rate,{'numeric'},{'scalar','finite','positive'});
end
