function roarm_timing_wait_benchmark(outdir)
% OFFLINE only: no serial Open, no controller commands, no timer-resolution changes.
assert(~isfolder(outdir));mkdir(outdir);
mode=[repmat("pause_1ms",200,1);repmat("pause_5ms",200,1);repmat("spin_1ms",200,1)];
requested_ms=[ones(200,1);5*ones(200,1);ones(200,1)];elapsed_ms=zeros(600,1);
for k=1:numel(mode)
    began=tic;
    if mode(k)=="spin_1ms"
        while toc(began)<.001,end
    else
        pause(requested_ms(k)/1000);
    end
    elapsed_ms(k)=1000*toc(began);
end
writetable(table(mode,requested_ms,elapsed_ms),fullfile(outdir,'wait_samples.csv'));
R=struct('matlab',version,'computer',computer,'serial_opened',false,'system_timer_changed',false);
for name=unique(mode,'stable')'
    v=elapsed_ms(mode==name);sorted=sort(v);
    R.(name)=struct('count',numel(v),'mean_ms',mean(v),'median_ms',median(v),'p95_ms',sorted(190),'max_ms',max(v));
end
try
    s=System.IO.Ports.SerialPort;
    s.PortName='COM15';s.BaudRate=115200;s.DtrEnable=false;s.RtsEnable=false;
    R.dotnet_serial_constructible=~s.IsOpen;
    s.Dispose();
catch err
    R.dotnet_serial_constructible=false;R.dotnet_error=err.message;
end
fid=fopen(fullfile(outdir,'summary.json'),'w');fprintf(fid,'%s',jsonencode(R,PrettyPrint=true));fclose(fid);
copyfile([mfilename('fullpath') '.m'],fullfile(outdir,'source.m'));
disp(R);
end
