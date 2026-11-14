function out=prc_wls(tau,g0,Y,weights,bounds)
%PRC_WLS Unregularized torque-to-payload WLS and separate physical projection.
% Inputs: tau/g0/weights 8-by-4, Y 8-by-4-by-3; phi=[m,m*cx,m*cz].
% weights multiply squared residuals (whitening uses sqrt(weights)).
% raw is never clipped. The optional bounded solution solves constrained WLS
% in phi, with common mass and COM bounds expressed as linear inequalities.
if nargin<4||isempty(weights),weights=ones(size(tau));end
if nargin<5,bounds=[];end
out=struct('raw_phi',nan(1,3),'raw_theta',nan(1,3),'phi',nan(1,3),'theta',nan(1,3), ...
    'bounded_phi',nan(1,3),'bounded_theta',nan(1,3),'rank',0,'condition',Inf, ...
    'singular_values',nan(1,3),'raw_valid',false,'bounded_valid',false,'accepted',false, ...
    'raw_within_bounds',false,'raw_objective',Inf,'bounded_objective',Inf, ...
    'bounded_exitflag',NaN,'ridge',0,'reasons',{{}},'effective_rows',0);
if ~isequal(size(tau),[8 4])||~isequal(size(g0),[8 4])||~isequal(size(Y),[8 4 3])|| ...
        ~isequal(size(weights),[8 4])||~isreal(tau)||~isreal(g0)||~isreal(Y)||~isreal(weights)|| ...
        ~all(isfinite(tau),'all')||~all(isfinite(g0),'all')||~all(isfinite(Y),'all')|| ...
        ~all(isfinite(weights),'all')||any(weights<0,'all')
    out.reasons={'invalid_wls_inputs'};return
end
A=reshape(double(Y),32,3);b=double(tau(:)-g0(:));w=double(weights(:));
keep=w>0;out.effective_rows=sum(keep);
if sum(keep)<3,out.reasons={'insufficient_positive_weight_rows'};return,end
A=A(keep,:).*sqrt(w(keep));b=b(keep).*sqrt(w(keep));
[U,S,V]=svd(A,0);sv=diag(S);out.singular_values=sv(:).';
tol=max(size(A))*eps(max([1;sv]));out.rank=sum(sv>tol);
if out.rank<3,out.reasons={'rank_deficient_wls'};return,end
out.condition=sv(1)/sv(3);phi=V*((U.'*b)./sv);
out.raw_phi=phi.';out.phi=out.raw_phi;out.raw_objective=sum((A*phi-b).^2);
if abs(phi(1))>1e-12
    out.raw_theta=[phi(1),phi(2)/phi(1),phi(3)/phi(1)];out.theta=out.raw_theta;
    out.raw_valid=all(isfinite(out.raw_theta));
else
    out.reasons{end+1}='raw_mass_too_close_to_zero';
end
out.accepted=out.raw_valid&&phi(1)>0;
if phi(1)<=0,out.reasons{end+1}='nonpositive_raw_mass';end
if isempty(bounds),return,end
B=double(bounds);
assert(isequal(size(B),[3 2])&&all(isfinite(B),'all')&&all(B(:,2)>B(:,1))&&B(1,1)>0, ...
    'prc:Bounds','Expected increasing 3-by-2 common bounds and positive minimum mass.');
out.raw_within_bounds=out.raw_valid&&all(out.raw_theta>=B(:,1).'-1e-12)&&all(out.raw_theta<=B(:,2).'+1e-12);
% cx_min*m <= hx <= cx_max*m, and similarly for hz; this is convex in phi.
C=[-B(2,2) 1 0;B(2,1) -1 0;-B(3,2) 0 1;B(3,1) 0 -1];
opt=optimoptions('lsqlin','Display','off','Algorithm','interior-point', ...
    'OptimalityTolerance',1e-10,'ConstraintTolerance',1e-10,'StepTolerance',1e-12);
try
    [bounded,~,~,flag]=lsqlin(A,b,C,zeros(4,1),[],[],[B(1,1);-Inf;-Inf],[B(1,2);Inf;Inf],[],opt);
    out.bounded_exitflag=flag;
    if flag>0&&all(isfinite(bounded))&&bounded(1)>0
        out.bounded_phi=bounded.';
        out.bounded_theta=[bounded(1),bounded(2)/bounded(1),bounded(3)/bounded(1)];
        out.bounded_objective=sum((A*bounded-b).^2);
        out.bounded_valid=all(out.bounded_theta>=B(:,1).'-1e-8)&&all(out.bounded_theta<=B(:,2).'+1e-8);
    else,out.reasons{end+1}='bounded_optimizer_failed';end
catch err
    out.reasons{end+1}=['bounded_optimizer_error:' err.identifier];
end
end
