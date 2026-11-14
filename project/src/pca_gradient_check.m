function report=pca_gradient_check(U,Y,amplitude,lossScales,epsilon,lambdas,opt)
%PCA_GRADIENT_CHECK Deterministic central differences; training arrays only.
p=3*size(U,2);points=[zeros(p,1),.1*sin((1:p).')];rows=struct([]);
for lambda=[lambdas(1),lambdas(end)]
    for point=1:size(points,2)
        x=points(:,point);[~,g,H]=pca_objective(x,U,Y,amplitude,lossScales,epsilon,lambda);fd=zeros(p,1);
        for j=1:p
            h=opt.difference_step*max(1,abs(x(j)));a=x;b=x;a(j)=a(j)+h;b(j)=b(j)-h;
            fd(j)=(pca_objective(a,U,Y,amplitude,lossScales,epsilon,lambda)- ...
                pca_objective(b,U,Y,amplitude,lossScales,epsilon,lambda))/(2*h);
        end
        gradError=norm(fd-g,inf)/max(1,norm(g,inf));hessianError=0;
        for direction=1:3
            v=sin((1:p).'*direction+.37);v=v/norm(v);h=opt.difference_step;
            [~,ga]=pca_objective(x+h*v,U,Y,amplitude,lossScales,epsilon,lambda);
            [~,gb]=pca_objective(x-h*v,U,Y,amplitude,lossScales,epsilon,lambda);
            hessianError=max(hessianError,norm((ga-gb)/(2*h)-H*v,inf)/max(1,norm(H*v,inf)));
        end
        r=struct('lambda',lambda,'point',point,'gradient_relative_error',gradError, ...
            'hessian_vector_relative_error',hessianError,'symmetric_error',norm(H-H.','inf'));
        if isempty(rows),rows=r;else,rows(end+1)=r;end %#ok<AGROW>
        assert(gradError<=opt.gradient_check_tolerance&&hessianError<=opt.hessian_check_tolerance, ...
            'pca:DerivativeCheck','Analytic derivative check failed.');
    end
end
report=struct('passed',true,'rows',rows,'rows_used',size(U,1),'parameters',p, ...
    'difference_step',opt.difference_step,'gradient_tolerance',opt.gradient_check_tolerance, ...
    'hessian_tolerance',opt.hessian_check_tolerance,'selection_uses_test',false);
end
