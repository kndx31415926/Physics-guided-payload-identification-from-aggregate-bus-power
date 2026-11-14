function x=bpil_features(obs,eta)
% Only measurable plateau signals and a calibrated nuisance model enter X.
q=obs.plateau_q;P=obs.plateau_P(:);
assert(size(q,1)==numel(P)&&size(q,2)==4,'bpil:Features','Bad observation shape');
assert(all(isfinite([q(:);P;eta.coefficients(:)])),'bpil:Features','Nonfinite data');
% Fixed vector length: 8 measured powers, 24 pitch angles, 4 electrical terms.
pitch=q(:,2:4);
x=[P.'/20,pitch(:).'/pi,eta.coefficients([1 3 4 5])./[2 2 4 4]];
end
