function model=pix_make_plant(cfg,payload,C,S)
%PIX_MAKE_PLANT Independent rigidBodyTree construction from shared geometry.
% No call to bpil_make_plant, bdclp_make_model, or any original servo step.
% MATLAB rigidBodyTree/rigidBody constructors consume the global stream for
% internal objects. These implementation details must not perturb callers.
caller_rng=rng;rng_cleanup=onCleanup(@()rng(caller_rng)); %#ok<NASGU>
p=cfg.legacy.geometry.robot_params;
validateattributes(payload.mass,{'numeric'},{'scalar','real','finite','nonnegative'});
c=double(payload.com(:).');validateattributes(c,{'numeric'},{'size',[1 3],'finite','real'});
if isfield(payload,'dimensions_m'),d=double(payload.dimensions_m(:).');else,d=cfg.payload.dimensions_m;end
assert(numel(d)==3&&all(isfinite(d))&&all(d>0),'pix:Payload','Invalid dimensions.');
margin=d/2-abs(c-[d(1)/2 0 0]);
assert(all(margin>0),'pix:Payload','Payload COM outside its declared envelope.');
if isfield(payload,'inertia')
    I=double(payload.inertia(:).');
else
    half=min(d/4,.8*margin);
    I=payload.mass/3*[half(2)^2+half(3)^2 half(1)^2+half(3)^2 half(1)^2+half(2)^2 0 0 0];
end
robot=rigidBodyTree('DataFormat','row','MaxNumBodies',6);robot.Gravity=p.gravity;
add('pix_pedestal',robot.BaseName,'fixed',[0 0 1],[0 0 0],[],p.fixed_base_mass,p.fixed_base_com_xyz,p.fixed_base_I6_com);
add('pix_yaw','pix_pedestal','revolute',[0 0 1],p.base_joint_xyz,p.jposlim(1,:),p.base_mass,p.base_com_xyz,p.base_I6_com);
names={'pix_upper','pix_forearm','pix_hand'};parents={'pix_yaw','pix_upper','pix_forearm'};
for j=1:3
    offset=[0 0 0];if j>1,offset(1)=p.L(j-1);end
    add(names{j},parents{j},'revolute',[0 1 0],offset,p.jposlim(j+1,:), ...
        p.mass(j)*C.link_mass_scale(j),p.com_xyz(j,:)+C.link_com_offset_m(j,:),p.I6_com(j,:)*C.link_mass_scale(j));
end
add('pix_payload','pix_hand','fixed',[0 0 1],[p.L(3) 0 0],[],payload.mass,c,I);
model=struct('robot',robot,'qmin',p.jposlim(:,1).','qmax',p.jposlim(:,2).', ...
    'parameters',p,'payload',struct('mass',double(payload.mass),'com',c,'inertia',I,'dimensions_m',d), ...
    'condition',C,'spec',S,'scope',S.scope);
    function add(name,parent,type,axis,xyz,limits,m,com,I6)
        body=rigidBody(name);joint=rigidBodyJoint([name '_joint'],type);
        if strcmp(type,'revolute'),joint.JointAxis=axis;joint.PositionLimits=limits;end
        T=eye(4);T(1:3,4)=xyz(:);setFixedTransform(joint,T);body.Joint=joint;
        com=double(com(:).');I6=double(I6(:).');
        assert(numel(I6)==6&&all(isfinite(I6)),'pix:Inertia','Invalid inertia vector.');
        Ic=[I6(1) I6(6) I6(5);I6(6) I6(2) I6(4);I6(5) I6(4) I6(3)];
        ev=sort(eig(Ic));assert(ev(1)>=-1e-12&&ev(3)<=sum(ev(1:2))+1e-12,'pix:Inertia','Nonphysical COM inertia.');
        Io=Ic+m*((com*com.')*eye(3)-com.'*com);
        body.Mass=m;body.CenterOfMass=com;
        body.Inertia=[Io(1,1) Io(2,2) Io(3,3) Io(2,3) Io(1,3) Io(1,2)];
        addBody(robot,body,parent);
    end
end
