function result=pca_solve_affine(x0,U,Y,amplitude,lossScales,smoothEpsilon,lambda,opt)
%PCA_SOLVE_AFFINE Deterministic full-batch damped Newton for a convex objective.
% Numerical stopping uses only training objective/derivatives, never validation.
x=double(x0(:));history=zeros(0,7);converged=false;reason='iteration_limit';
wall=tic;dampingEvents=0;
for iteration=0:opt.max_iterations
    [f,g,H,parts]=pca_objective(x,U,Y,amplitude,lossScales,smoothEpsilon,lambda);
    assert(isfinite(f)&&all(isfinite(g))&&all(isfinite(H),'all'),'pca:Nonfinite','Nonfinite objective.');
    scale=1./sqrt(max(diag(H),realmin));B=(H.*scale).*scale.';
    [R,flag]=chol(B);damping=0;
    if flag~=0
        damping=opt.initial_damping;
        while flag~=0&&damping<=opt.maximum_damping
            [R,flag]=chol(B+damping*eye(numel(x)));if flag~=0,damping=damping*10;end
        end
        assert(flag==0,'pca:Hessian','Unable to factor scaled convex Hessian.');dampingEvents=dampingEvents+1;
    end
    scaledDirection=-(R\(R.'\(scale.*g)));direction=scale.*scaledDirection;
    linearResidual=norm((B+damping*eye(numel(x)))*scaledDirection+scale.*g,inf)/max(realmin,norm(scale.*g,inf));
    decrease=-g.'*direction;gradientNorm=norm(g,inf);
    history(end+1,:)=[iteration f parts.data_loss parts.weight_L2_penalty gradientNorm decrease damping]; %#ok<AGROW>
    if gradientNorm<=opt.gradient_tolerance&&decrease/2<=opt.decrement_relative_tolerance*max(1,abs(f))
        converged=true;reason='gradient_and_newton_decrement';break
    end
    if iteration==opt.max_iterations,break;end
    assert(decrease>0&&isfinite(decrease),'pca:Direction','Newton direction is not descent.');
    step=1;accepted=false;
    for backtrack=0:opt.max_backtracks
        trial=x+step*direction;
        next=pca_objective(trial,U,Y,amplitude,lossScales,smoothEpsilon,lambda);
        if isfinite(next)&&next<=f-opt.armijo*step*decrease
            accepted=true;break
        end
        step=step/2;
    end
    if ~accepted,reason='line_search_stalled';break;end
    x=trial;
end
[f,g,H,parts]=pca_objective(x,U,Y,amplitude,lossScales,smoothEpsilon,lambda);
scale=1./sqrt(max(diag(H),realmin));scaledH=(H.*scale).*scale.';
result=struct('schema','pca_affine_solution_v1','coefficients',reshape(x,3,size(U,2)), ...
    'lambda',lambda,'converged',converged,'reason',reason,'iterations',iteration, ...
    'objective',f,'gradient_inf',norm(g,inf),'scaled_gradient_inf',norm(scale.*g,inf), ...
    'scaled_linear_solve_relative_residual',linearResidual,'scaled_hessian_rcond',rcond(scaledH), ...
    'objective_parts',parts,'damping_events',dampingEvents,'history',history, ...
    'history_columns',{{'iteration','objective','smooth_data_loss','L2_penalty','gradient_inf','newton_decrement','damping'}}, ...
    'wall_s',toc(wall));
end
