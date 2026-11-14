function phi=prc_lao_solve_dl(Y,residual,weights,column_scale,ridge)
%PRC_LAO_SOLVE_DL Differentiable double-precision 3-parameter WLS.
% Y:32x3xB, residual/weights:32xB. Columns are scaled using training data.
% The fixed ridge only stabilizes training, not final unregularized inference.
% Explicit batched 3x3 Cholesky uses supported dlarray operations throughout;
% no extractdata, inverse, detached solve, or label-dependent regularization.
B=size(residual,2);A=double(Y)./reshape(column_scale,1,3,1);
a=reshape(A(:,1,:),32,B);b=reshape(A(:,2,:),32,B);c=reshape(A(:,3,:),32,B);
g11=sum(weights.*a.^2,1)/32+ridge;g22=sum(weights.*b.^2,1)/32+ridge;
g33=sum(weights.*c.^2,1)/32+ridge;g12=sum(weights.*a.*b,1)/32;
g13=sum(weights.*a.*c,1)/32;g23=sum(weights.*b.*c,1)/32;
d1=sum(weights.*a.*residual,1)/32;d2=sum(weights.*b.*residual,1)/32;
d3=sum(weights.*c.*residual,1)/32;
l11=sqrt(g11);l21=g12./l11;l31=g13./l11;
l22=sqrt(g22-l21.^2);l32=(g23-l31.*l21)./l22;
l33=sqrt(g33-l31.^2-l32.^2);
y1=d1./l11;y2=(d2-l21.*y1)./l22;y3=(d3-l31.*y1-l32.*y2)./l33;
z3=y3./l33;z2=(y2-l32.*z3)./l22;z1=(y1-l21.*z2-l31.*z3)./l11;
phi=[z1/column_scale(1);z2/column_scale(2);z3/column_scale(3)];
end
