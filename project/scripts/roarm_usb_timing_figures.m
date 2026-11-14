function outputs = roarm_usb_timing_figures(resultDirectory)
%ROARM_USB_TIMING_FIGURES Plot completed read-only USB timing observations.
% This function does not open serial ports or issue hardware commands.
% Run only after acquisition has exited. All figures are generated in MATLAB.
arguments
    resultDirectory (1,1) string
end
S = jsondecode(fileread(fullfile(resultDirectory,'summary.json')));
status = jsondecode(fileread(fullfile(resultDirectory,'status.json')));
assert(any(strcmp(status.state, {'complete','failed','stopped','aborted'})), ...
    'Timing acquisition has not terminated; do not plot during measurement.');
T = readtable(fullfile(resultDirectory,'samples.csv'), 'TextType','string', ...
    'VariableNamingRule','preserve');
Q = readtable(fullfile(resultDirectory,'stage_summary.csv'), 'TextType','string', ...
    'VariableNamingRule','preserve');
assert(ismember('stage', string(T.Properties.VariableNames)), 'Missing stage column.');
numericNames = ["tx_start_s","rx_frame_s"];
for name = numericNames
    if ~isnumeric(T.(name)), T.(name) = str2double(T.(name)); end
end
main = startsWith(T.stage, 'main_20hz_');
ok = T.status == "ok";
mainOk = main & ok & isfinite(T.tx_start_s) & isfinite(T.rx_frame_s);
rtt = 1000*(T.rx_frame_s(mainOk)-T.tx_start_s(mainOk));
assert(all(rtt >= 0), 'Negative RTT in source data.');
F = figure('Visible','off','Color','w','Position',[50 50 1550 1170]);
cleanup = onCleanup(@() close(F));
set(F,'DefaultAxesFontName','Arial','DefaultAxesFontSize',12);
L = tiledlayout(F,3,1,'TileSpacing','compact','Padding','compact');
title(L,'RoArm-M2-S: host-observed, read-only USB timing', 'FontWeight','bold', 'FontSize',18);
subtitle(L,'T105 polling only; motion-command execution, full control loop and bus-power acquisition were not tested', ...
    'FontSize',11);

ax1 = nexttile(L); hold(ax1,'on');
if any(mainOk)
    origin = min(T.tx_start_s(main));
    plot(ax1,T.tx_start_s(mainOk)-origin,rtt,'.','Color',[0.03 0.40 0.72], ...
        'MarkerSize',4,'DisplayName','Complete-reply RTT');
    names = unique(T.stage(main),'stable');
    firstInterval = true;
    for name = names'
        subset = T.stage == name & isfinite(T.tx_start_s);
        ts = T.tx_start_s(subset);
        if numel(ts)>1
            if firstInterval
                plot(ax1,ts(2:end)-origin,1000*diff(ts),'.','Color',[0.65 0.65 0.65], ...
                    'MarkerSize',4,'DisplayName','Actual request interval');
                firstInterval = false;
            else
                plot(ax1,ts(2:end)-origin,1000*diff(ts),'.','Color',[0.65 0.65 0.65], ...
                    'MarkerSize',4,'HandleVisibility','off');
            end
        end
    end
else
    text(ax1,0.5,0.5,'No successful 20-Hz main-stage samples','Units','normalized','HorizontalAlignment','center');
end
yline(ax1,50,'--','Nominal 50 ms','Color',[0.78 0.20 0.16], ...
    'HandleVisibility','off','LabelHorizontalAlignment','left');
grid(ax1,'on'); ylabel(ax1,'Host-observed time (ms)');
xlabel(ax1,'Elapsed time from first main-stage request (s)');
title(ax1,'(a) Three nominal 20-Hz rounds; intervals exclude stage boundaries');
if any(mainOk), legend(ax1,'Location','eastoutside'); end

ax2 = nexttile(L); hold(ax2,'on');
if ~isempty(rtt)
    sorted = sort(rtt);
    stairs(ax2,sorted,(1:numel(sorted))'/numel(sorted), ...
        'Color',[0.03 0.40 0.72],'LineWidth',1.8,'DisplayName',sprintf('20-Hz replies (n = %d)',numel(sorted)));
    xmax = max(55,max(sorted)*1.06);
    xlim(ax2,[0 xmax]); ylim(ax2,[0 1.02]);
    stats = S.main_20hz_pooled.timing.host_rtt;
    label = sprintf('P50 %.2f ms | P95 %.2f ms | P99 %.2f ms | max %.2f ms', ...
        stats.p50_ms,stats.p95_ms,stats.p99_ms,stats.max_ms);
    text(ax2,0.02,0.20,label,'Units','normalized','FontSize',11,'BackgroundColor','w');
    legend(ax2,'Location','southeast');
else
    text(ax2,0.5,0.5,'RTT distribution unavailable','Units','normalized','HorizontalAlignment','center');
end
xline(ax2,50,'--','50 ms','Color',[0.78 0.20 0.16],'HandleVisibility','off');
grid(ax2,'on'); xlabel(ax2,'Complete-reply RTT (ms)'); ylabel(ax2,'Empirical cumulative fraction');
title(ax2,'(b) Successful-reply latency; timeout and unattempted counts are reported separately');

ax3 = nexttile(L);
Q = Q(Q.stage ~= "warmup_10hz",:);
frequencyNames = ["target_hz","request_hz","reply_hz"];
for name = frequencyNames
    if ~isnumeric(Q.(name)), Q.(name)=str2double(Q.(name)); end
end
bars = bar(ax3,1:height(Q),[Q.target_hz,Q.request_hz,Q.reply_hz],'grouped');
bars(1).FaceColor=[0.72 0.72 0.72];
bars(2).FaceColor=[0.03 0.40 0.72];
bars(3).FaceColor=[0.17 0.61 0.43];
labels = replace(Q.stage,["baseline_","main_","stress_"],["baseline ","main ","stress "]);
labels = replace(labels,"_"," ");
xticks(ax3,1:height(Q)); xticklabels(ax3,labels);
xtickangle(ax3,0); grid(ax3,'on'); ylabel(ax3,'Frequency (Hz)');
legend(ax3,{'Target schedule','Observed requests','Successful replies'},'Location','eastoutside');
title(ax3,'(c) Stage frequency = (n - 1)/(last - first); missing bars mean unmeasured');
for k = 1:height(Q)
    text(ax3,k,Q.target_hz(k)+1.0,sprintf('%d/%d',Q.success(k),Q.planned(k)), ...
        'HorizontalAlignment','center','FontSize',10);
end
ylim(ax3,[0 max(Q.target_hz)*1.18]);
xlabel(ax3,'Labels above bars: successful replies / planned requests');

pngPath=fullfile(resultDirectory,'usb_timing_overview.png');
pdfPath=fullfile(resultDirectory,'usb_timing_overview.pdf');
figPath=fullfile(resultDirectory,'usb_timing_overview.fig');
assert(~isfile(pngPath) && ~isfile(pdfPath) && ~isfile(figPath), ...
    'Figure output already exists; preserve it or choose a new output directory.');
exportgraphics(F,pngPath,'Resolution',220);
exportgraphics(F,pdfPath,'ContentType','vector');
savefig(F,figPath);
outputs=struct('png',pngPath,'pdf',pdfPath,'fig',figPath, ...
    'scope','Read-only host-observed communication; control execution unmeasured');
disp(outputs);
end
