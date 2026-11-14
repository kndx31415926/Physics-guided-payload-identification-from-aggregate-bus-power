function result=pvi_rank_bound(g0,Y,coeff,B,max_nodes)
%PVI_RANK_BOUND Numerically evaluate a uniform-rank sufficient bound.
% J_beta is affine in beta. Weyl's inequality gives, on each beta box,
% sigma_min(J(center)S) - sum_j radius_j*norm(dJ/dbeta_j*S,2).
% Theta boxes cover the physical beta polytope through conservative beta
% interval boxes. Positive lower bounds cover the continuous domain, rather
% than only sampling its grid. Arithmetic is double, not directed intervals.
if nargin<5,max_nodes=200000;end
blo=[B(1,1),B(1,1)*B(2,1),B(1,2)*B(3,1)];
bhi=[B(1,2),B(1,2)*B(2,2),B(1,2)*B(3,2)];
S=bhi-blo;derivative_norm=zeros(1,3);
for j=1:3
 A=zeros(size(g0,1),3);
 for k=1:3,A(:,k)=2*sum(Y(:,:,j).*Y(:,:,k).*coeff(2:5),2)*S(k);end
 derivative_norm(j)=norm(A,2)*(1+1e-12);
end
queue=zeros(max_nodes+2,6);queue(1,:)=[B(:,1).' B(:,2).'];head=1;tail=1;
covered=0;lower=Inf;min_margin=Inf;max_depth=0;depth=zeros(max_nodes+2,1);unresolved=0;
while head<=tail&&head<=max_nodes
 box=queue(head,:);lo=box(1:3);hi=box(4:6);dep=depth(head);head=head+1;
 vals=[lo(1)*lo(3),lo(1)*hi(3),hi(1)*lo(3),hi(1)*hi(3)];
 bl=[lo(1),lo(1)*lo(2),min(vals)];bh=[hi(1),hi(1)*hi(2),max(vals)];
 bc=(bl+bh)/2;br=(bh-bl)/2;t=[bc(1),bc(2:3)/bc(1)];
 [~,J]=pvi_power_model(g0,Y,t,coeff);ss=svd(J.*S,0);smin=ss(end);
 variation=br*derivative_norm.';roundoff_margin=1e-10*max(1,norm(J.*S,2)+variation);
 bound=smin-variation-roundoff_margin;
 if bound>0
  covered=covered+1;lower=min(lower,bound);min_margin=min(min_margin,bound/max(roundoff_margin,realmin));max_depth=max(max_depth,dep);
 else
  if tail+2>max_nodes||dep>=30,unresolved=unresolved+1;continue,end
  [~,axis]=max((hi-lo)./diff(B,1,2).');middle=(lo(axis)+hi(axis))/2;
  b1=box;b2=box;b1(axis+3)=middle;b2(axis)=middle;
  queue(tail+1:tail+2,:)=[b1;b2];depth(tail+1:tail+2)=dep+1;tail=tail+2;
 end
end
unresolved=unresolved+max(0,tail-head+1);
result=struct('continuous_domain_covered',unresolved==0,'certified_boxes',covered, ...
 'visited_nodes',head-1,'unresolved_boxes',unresolved,'max_bisection_depth',max_depth, ...
 'uniform_scaled_singular_lower_bound',lower,'min_lower_bound_over_roundoff_margin',min_margin, ...
 'beta_column_scale',S,'derivative_spectral_bounds',derivative_norm, ...
 'arithmetic','Double precision, safety margin 1e-10*max(1,norm); not directed-rounding interval certification.', ...
 'claim','Conditional quadratic midpoint theorem; sufficient bound evaluated numerically over a full box cover.');
end
