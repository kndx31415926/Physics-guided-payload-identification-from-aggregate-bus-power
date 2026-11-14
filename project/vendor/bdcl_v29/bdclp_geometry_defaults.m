function G=bdclp_geometry_defaults()
%BDCLP_GEOMETRY_DEFAULTS Central nominal geometry and geometric-planner contract.
% These are modelling/task assumptions, not measured servo calibration.
G.schema='bdclp_reduced_roarm_geometry_v1';
G.robot_params=spinn3d_roarm_m2s_nominal_params();
G.robot_params.actuator_model_boundary=[ ...
    'Nominal mechanical data only; the new execution layer receives position commands. ', ...
    'Servo dynamics are separate uncalibrated modelling assumptions, not inverse-dynamics commands.'];
G.default=[0.22 0.020 0.30 0.28];
G.lower=[0.150 -0.060 0.180 0.160];
G.upper=[0.300 0.060 0.380 0.360];
G.parameter_names={'lift_m','lateral_m','first_control_fraction','last_control_fraction'};
G.q0=pi/180*[-30 50 -35 -15];
G.qf=pi/180*[0 -25 -120 50];
G.payload_contract='task.payload is the sole geometry/COM/inertia source; rigid wrist attachment, no grasp process';
G.velocity_max_rad_s=40*2*pi/60*ones(1,4);
G.acceleration_max_rad_s2=18*ones(1,4);
G.motion_limit_status='selected operating/task limits; acceleration is not a manufacturer rating';
G.plane_z_m=-0.25;
G.plane_clearance_m=0.010;
G.self_clearance_m=0.003;
G.capsule_body_names={'base_fixed','link_baseYaw','link_shoulder','link_elbow','link_wrist'};
G.capsule_start_m=[0 0 0;0 0 -0.045;0 0 0;0 0 0;0 0 0];
p=G.robot_params;
G.capsule_end_m=[0 0 p.base_height;0 0 0;p.L(1) 0 0;p.L(2) 0 0;p.L(3) 0 0];
G.capsule_radius_m=[p.base_radius 0.035 p.link_radius p.link_radius p.link_radius];
G.collision_pairs=[1 4;1 5;2 4;2 5;3 5];
G.payload_capsule_indices=[1 2 3 4];
G.payload_collision_model='conservative circumsphere versus nonadjacent capsules; eight OBB corners versus plane';
G.audit_tolerance=1e-10;
G.builder=bdclp_route_builder_defaults();
G.maximum_cartesian_error_m=0.015;
G.pitch_rule='position task with soft angular-step regularization and null-space posture preference; no prescribed interior pitch';
G.dls_finite_difference_rad=1e-6;
G.route_audit_scope=['Convex B-spline joint domain; dense actual composed derivative audit; ', ...
    'sampled Cartesian and collision audit, not a continuous collision certificate'];
G.hardware_calibrated=false;
G.joint_domain_scope=['Explicit research exception: current reduced joint ', ...
    'domain and endpoints are retained and need not be stock T102 reachable. ', ...
    'A calibrated stock interface must reject out-of-range commands.'];
G.inertia_convention='rigidBody.Inertia about body-frame origin; COM source tensors translated exactly once';
G.inertia_reference='https://www.mathworks.com/matlabcentral/answers/2042131-why-do-rigid-bodies-moment-of-inertia-values-seemingly-change-when-generating-a-model-with-smimpor';
end
