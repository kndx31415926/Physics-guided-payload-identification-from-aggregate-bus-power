function output=prc_lao_forward(parameters,X,kind)
%PRC_LAO_FORWARD Lao-style joint encoders with independent representations.
% X is 4 features x 4 joints x samples; unformatted double dlarray supported.
% Hidden layers use ReLU, torque/score output layers are linear.
S=size(X,3);h=cell(1,4);
for j=1:4
    prefix=sprintf('j%d_',j);x=reshape(X(:,j,:),4,S);
    a=relu(parameters.([prefix 'w1'])*x+parameters.([prefix 'b1']));
    h{j}=relu(parameters.([prefix 'w2'])*a+parameters.([prefix 'b2']));
end
if strcmp(kind,'torque')
    a=cat(1,h{:});a=relu(parameters.h1w*a+parameters.h1b);
    a=relu(parameters.h2w*a+parameters.h2b);output=parameters.h3w*a+parameters.h3b;
elseif strcmp(kind,'attention')
    scores=cell(1,4);identity=eye(4);
    for j=1:4
        z=[h{j};repmat(identity(:,j),1,S)];
        z=relu(parameters.sw1*z+parameters.sb1);scores{j}=parameters.sw2*z+parameters.sb2;
    end
    scores=cat(1,scores{:});ex=exp(scores-max(scores,[],1));output=ex./sum(ex,1);
else
    error('prc:LaoKind','Unknown model stage.');
end
end
