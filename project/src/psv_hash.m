function h=psv_hash(value)
% Deterministic JSON identity for a frozen semantic plan.
md=javaMethod('getInstance','java.security.MessageDigest','SHA-256');
md.update(unicode2native(jsonencode(value),'UTF-8'));
h=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
