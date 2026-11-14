function R=bdclp_reference_profile(q,v,goal,vmax,amax,dt)
%BDCLP_REFERENCE_PROFILE Continuous bounded-acceleration internal reference.
% Each axis uses exact constant-acceleration segments. A nearby target can
% require braking past it and returning; no target/zero-speed snap is used.
% This is an explicit nominal profile, not identified ST3215 firmware.
q=row4(q);v=row4(v);goal=row4(goal);vmax=row4(vmax);amax=row4(amax);
assert(all(vmax>0)&&all(amax>0)&&isscalar(dt)&&isreal(dt)&&isfinite(dt)&&dt>0, ...
    'bdclp:ReferenceProfile','Positive speed, acceleration and duration are required.');
R=struct('q_end',q,'v_end',v,'q_mid',q,'v_mid',v, ...
    'event_times_s',{{}},'initial_speed_above_new_limit',abs(v)>vmax, ...
    'scope','analytic_piecewise_constant_acceleration_unidentified_firmware');
R.event_times_s=cell(1,4);
for j=1:4
    [segments,total]=plan_axis(q(j),v(j),goal(j),vmax(j),amax(j));
    [R.q_mid(j),R.v_mid(j)]=sample_axis(segments,total,goal(j),dt/2);
    [R.q_end(j),R.v_end(j)]=sample_axis(segments,total,goal(j),dt);
    edges=[segments.start]+[segments.duration];
    R.event_times_s{j}=edges(edges>0 & edges<dt);
end
end

function [S,total]=plan_axis(p,v,g,vm,a)
S=struct('q',{},'v',{},'a',{},'start',{},'duration',{});total=0;
% A newly reduced speed setting cannot instantaneously change an existing
% velocity. Decelerate to its new bound and disclose the initial excess.
if abs(v)>vm
    signv=sign(v);duration=(abs(v)-vm)/a;
    append(-signv*a,duration);v=signv*vm;
end
distance=g-p;
if v~=0 && (distance*v<=0 || v^2/(2*a)>=abs(distance))
    % This includes moving away, a target behind the stopping point, and
    % the exact stopping-distance case. Passing g at nonzero v is allowed.
    append(-sign(v)*a,abs(v)/a);v=0;
end
distance=g-p;
if distance~=0
    direction=sign(distance);d=abs(distance);u=direction*v;
    assert(u>=-1e-12&&u<=vm*(1+1e-12),'bdclp:ReferenceProfile', ...
        'Internal profile planning state is inconsistent.');
    u=max(0,u);
    peak=min(vm,sqrt(a*d+0.5*u^2));
    acceleration_time=max(0,(peak-u)/a);
    acceleration_distance=(peak^2-u^2)/(2*a);
    braking_distance=peak^2/(2*a);
    cruise_time=max(0,(d-acceleration_distance-braking_distance)/peak);
    append(direction*a,acceleration_time);v=direction*peak;
    append(0,cruise_time);
    append(-direction*a,peak/a);v=0; %#ok<NASGU>
end
% Endpoint assignment occurs only after the complete analytically planned
% braking interval, absorbing arithmetic roundoff rather than early arrival.

    function append(acceleration,duration)
        if duration<=0,return;end
        assert(isfinite(duration)&&isfinite(acceleration), ...
            'bdclp:ReferenceProfile','Nonfinite profile segment.');
        S(end+1)=struct('q',p,'v',v,'a',acceleration, ...
            'start',total,'duration',duration); %#ok<AGROW>
        p=p+v*duration+0.5*acceleration*duration^2;
        v=v+acceleration*duration;
        total=total+duration;
    end
end

function [p,v]=sample_axis(S,total,goal,t)
if t>=total,p=goal;v=0;return;end
k=find(t<[S.start]+[S.duration],1,'first');
assert(~isempty(k),'bdclp:ReferenceProfile','Missing profile segment.');
u=t-S(k).start;
p=S(k).q+S(k).v*u+0.5*S(k).a*u^2;
v=S(k).v+S(k).a*u;
end

function x=row4(x)
assert(isnumeric(x)&&isreal(x)&&isequal(size(x),[1 4])&&all(isfinite(x)), ...
    'bdclp:ReferenceProfile','Inputs must be finite real 1x4 rows.');
x=double(x);
end
