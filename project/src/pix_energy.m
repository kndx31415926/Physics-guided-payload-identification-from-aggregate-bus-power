function E=pix_energy(model,x)
%PIX_ENERGY Independent stored-energy evaluation, all quantities in joules.
% Accessing MATLAB Bodies/transform objects can consume its global RNG.
caller_rng=rng;rng_cleanup=onCleanup(@()rng(caller_rng)); %#ok<NASGU>
q=x(1:4).';v=x(5:8).';S=model.spec;
E.kinetic_J=.5*v*massMatrix(model.robot,q)*v.';
potential=0;
for j=1:model.robot.NumBodies
    b=model.robot.Bodies{j};T=getTransform(model.robot,q,b.Name);
    world=T(1:3,1:3)*b.CenterOfMass(:)+T(1:3,4);
    potential=potential-b.Mass*dot(model.robot.Gravity(:),world);
end
E.potential_J=potential;E.mechanical_J=E.kinetic_J+potential;
E.magnetic_J=.5*sum(S.L_H.*x(9:12).'.^2);
E.winding_thermal_J=sum(S.heat_capacity_J_per_K.*(x(17:20).'-S.ambient_C));
end
