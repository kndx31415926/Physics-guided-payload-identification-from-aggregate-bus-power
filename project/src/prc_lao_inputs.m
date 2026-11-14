function X=prc_lao_inputs(state,normalization)
%PRC_LAO_INPUTS Apply train-only minmax q and max-absolute error scales.
% No inference-time clipping to training ranges: extrapolation remains visible.
% Direction channels are preserved verbatim, including [0,0] when unknown.
N=size(state,1);assert(size(state,2)==8&&size(state,3)==4&&size(state,4)==4, ...
    'prc:LaoState','Expected N-by-8-by-4-by-4 state.');
X=reshape(permute(double(state),[4 3 2 1]),4,4,8*N);
for j=1:4
    X(1,j,:)=(X(1,j,:)-normalization.q_min(j))/normalization.q_span(j);
    X(2,j,:)=X(2,j,:)/normalization.error_scale(j);
end
end
