function theta=bpil_student_predict(student,X)
theta=predict(student.model,X).*student.scale;
theta=max(student.bounds(:,1).',min(student.bounds(:,2).',theta));
end
