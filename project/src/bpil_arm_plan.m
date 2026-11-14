function P=bpil_arm_plan(waypoints,move_s,hold_s,dt_s)
%BPIL_ARM_PLAN Pure quintic waypoint plan in MODEL joint radians.
% First waypoint is the required already-achieved start; no hidden approach.
% P uses a 50-ms grid. Delayed execution stretches time, never catches up.
if nargin<4,dt_s=.05;end
validateattributes(waypoints,{'numeric'},{'2d','ncols',4,'nonempty','real','finite'});
validateattributes(move_s,{'numeric'},{'scalar','real','finite','positive'});
validateattributes(hold_s,{'numeric'},{'scalar','real','finite','nonnegative'});
assert(abs(dt_s-.05)<1e-12,'bpil:ArmPlanCadence','The command plan uses a 50-ms grid.');
nm=round(move_s/dt_s);nh=round(hold_s/dt_s);
assert(nm>=1&&abs(nm*dt_s-move_s)<1e-10&&abs(nh*dt_s-hold_s)<1e-10, ...
    'bpil:ArmPlanGrid','Move and hold durations must be integer multiples of 50 ms.');
assert(size(waypoints,1)<=1000&&nm<=1e5&&nh<=1e5,'bpil:ArmPlanSize','Plan is too large.');
count=1+nh+(size(waypoints,1)-1)*(nm+nh);
assert(count<=1e6,'bpil:ArmPlanSize','Plan exceeds one million samples.');
q=zeros(count,4);q(1,:)=waypoints(1,:);cursor=1;
if nh>0,q(cursor+(1:nh),:)=repmat(waypoints(1,:),nh,1);cursor=cursor+nh;end
for k=2:size(waypoints,1)
    u=(1:nm)'/nm;b=10*u.^3-15*u.^4+6*u.^5;
    q(cursor+(1:nm),:)=waypoints(k-1,:)+b.*(waypoints(k,:)-waypoints(k-1,:));cursor=cursor+nm;
    if nh>0,q(cursor+(1:nh),:)=repmat(waypoints(k,:),nh,1);cursor=cursor+nh;end
end
P=struct('schema','bpil_arm_plan_v1','t',(0:count-1)'*dt_s,'q',q, ...
    'waypoints',waypoints,'move_s',move_s,'hold_s',hold_s,'control_dt_s',dt_s, ...
    'requires_preposition',true,'generated_by','quintic_between_waypoints', ...
    'scope','Joint-space plan only; this does not establish obstacle or fixture clearance.');
end
