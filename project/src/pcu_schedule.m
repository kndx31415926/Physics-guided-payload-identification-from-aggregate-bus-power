function yes=pcu_schedule(block,interval)
% Shared first reference access, then every interval blocks: 1:k:B.
assert(isscalar(block)&&block>=1&&block==fix(block)&&isscalar(interval)&& ...
    interval>=1&&interval==fix(interval),'pcu:Schedule','Positive integer indices required.');
yes=mod(block-1,interval)==0;
end
