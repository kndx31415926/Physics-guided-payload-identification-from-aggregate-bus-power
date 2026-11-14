function outdir=roarm_hefting_presets_preview(outdir)
% Offline kinematic preview for the STOCK gripper in mode 0.
% This file never opens a serial port. Angles below are stock wire coordinates,
% not the reduced wrist-model coordinates used by the research controller.
if nargin<1
    outdir=fullfile('C:/new/results',['hefting_presets_preview_' char(datetime('now','Format','yyyyMMdd_HHmmss'))]);
end
assert(~isfolder(outdir),'Refusing to overwrite an existing preview.');
mkdir(outdir);copyfile([mfilename('fullpath') '.m'],fullfile(outdir,'preview_source.m'));
dt=.05;
names={'01 小臂轻抬','02 慢快双节奏','03 平托前后移','04 肩肘组合'};
subtitles={'肘关节抬起 8°，再回到起点', ...
    '同样抬起 8°，先慢后稍快', ...
    '肩肘反向各 6°，保持前臂方向', ...
    '先抬肘，再改变肩部姿态，分步回位'};
offsets={ [0 0;0 -8;0 0], [0 0;0 -8;0 0;0 -8;0 0], ...
    [0 0;-6 6;6 -6;0 0], [0 0;0 -8;-6 -8;-6 0;0 0]};
durations={ [2 2],[2 2 1.4 1.4],[2 2 2],[2 2 2 2]};
colors=[.02 .48 .48;.18 .38 .78;.65 .31 .12;.44 .31 .70];
presets=struct([]);
for k=1:4
    W=[zeros(size(offsets{k},1),1),offsets{k}+[0 90],180*ones(size(offsets{k},1),1)];
    [tt,qq,phase]=plan(W,durations{k},dt);
    [elbow,tip]=geometry(qq);
    assert(max(abs(qq(:,1)))==0 && max(abs(qq(:,4)-180))==0);
    assert(max(abs(qq(1,:)-qq(end,:)))<1e-10);
    assert(max(abs(diff(tt)-dt))<1e-10);
    assert(all(isfinite(tip),'all'));
    velocity=diff(qq)/dt;acceleration=diff(qq,2)/dt^2;
    presets(k).name=names{k};presets(k).description=subtitles{k};
    presets(k).time_s=tt;presets(k).wire_joint_deg=qq;
    presets(k).wire_joint_rad=deg2rad(qq);presets(k).phase=phase;
    presets(k).elbow_m=elbow;presets(k).tip_m=tip;
    presets(k).duration_s=tt(end);presets(k).peak_speed_deg_s=max(abs(velocity),[],1);
    presets(k).peak_acceleration_deg_s2=max(abs(acceleration),[],1);
    presets(k).hold_at_start_s=1;presets(k).hold_at_end_s=2;
    presets(k).scope='Offline stock-mode0 kinematic preview only; not a robot execution file or dynamics/holding validation.';
    T=table(tt,qq(:,1),qq(:,2),qq(:,3),qq(:,4),phase, ...
        'VariableNames',{'time_s','base_deg','shoulder_deg','elbow_deg','gripper_deg','phase'});
    writetable(T,fullfile(outdir,sprintf('preset_%02d_preview_only.csv',k)));
end
metadata=struct('schema','roarm_stock_gripper_preview_v1','control_grid_s',dt, ...
    'robot_commands_sent',0,'hardware_executable',false,'dynamics_simulated',false, ...
    'joint_coordinates','stock mode0 b,s,e,t; fourth axis is gripper opening', ...
    'reference_pose_deg',[0 0 90 180], ...
    'geometry_source','Audited Waveshare mode0 FK: L2A=236.82 mm,L2B=30 mm,L3A=280.15 mm,L3B=1.73 mm', ...
    'limitation','Ideal encoder geometry, no actual assembly offsets, collisions, compliance, payload, power or identifiability validation.');
save(fullfile(outdir,'presets_preview_only.mat'),'presets','metadata');
writeText(fullfile(outdir,'metadata.json'),jsonencode(metadata,PrettyPrint=true));

f=figure('Color',[.965 .974 .981],'Position',[80 50 1200 880], ...
    'Visible','off','Renderer','opengl','MenuBar','none','ToolBar','none');
cleanup=onCleanup(@()close(f));
set(f,'DefaultTextFontName','Microsoft YaHei','DefaultAxesFontName','Microsoft YaHei');
tl=tiledlayout(f,2,2,'Padding','compact','TileSpacing','compact');
title(tl,'掂量动作预览  /  原装夹爪固定', 'FontSize',21,'FontWeight','bold');
subtitle(tl,'MATLAB 几何动画 · 未驱动实机 · 每次到位停留，最终停留 2 秒','FontSize',12);
h=struct([]);
for k=1:4
    ax=nexttile(tl);hold(ax,'on');axis(ax,'equal');
    xlim(ax,[-.07 .40]);ylim(ax,[-.055 .355]);
    ax.Color='white';ax.XColor=[.4 .45 .5];ax.YColor=ax.XColor;
    ax.GridAlpha=.10;grid(ax,'on');box(ax,'off');
    xlabel(ax,'前后位置 / m');ylabel(ax,'相对肩轴高度 / m');
    title(ax,{names{k};subtitles{k}},'FontSize',13,'FontWeight','bold');
    % The grey line is the L reference; coloured line is commanded ideal geometry.
    [ee,pp]=geometry([0 0 90 180]);
    plot(ax,[0 ee(1) pp(1)],[0 ee(2) pp(2)],'-','Color',[.82 .86 .89],'LineWidth',9);
    plot(ax,presets(k).tip_m(:,1),presets(k).tip_m(:,2),':','Color',colors(k,:),'LineWidth',1.6);
    rectangle(ax,'Position',[-.027 -.026 .054 .022],'Curvature',.2,'FaceColor',[.21 .25 .31],'EdgeColor','none');
    h(k).arm=plot(ax,nan,nan,'-o','Color',colors(k,:),'LineWidth',7, ...
        'MarkerSize',10,'MarkerFaceColor','white','MarkerEdgeColor',colors(k,:));
    h(k).tip=plot(ax,nan,nan,'s','Color',colors(k,:),'MarkerSize',11,'MarkerFaceColor',colors(k,:));
    h(k).jaw=plot(ax,nan,nan,'-','Color',[.17 .21 .28],'LineWidth',2.5);
    h(k).status=text(ax,-.055,.327,'','FontSize',12,'Color',colors(k,:),'FontWeight','bold');
    h(k).angles=text(ax,-.055,-.045,'','FontSize',10,'Color',[.25 .30 .36],'VerticalAlignment','bottom');
end
% Overview: select the most informative pose of each candidate.
for k=1:4
    q=presets(k).wire_joint_deg;
    [~,ix]=max(sum((q(:,2:3)-[0 90]).^2,2));
    update(k,ix);
end
drawnow;
exportgraphics(f,fullfile(outdir,'preset_overview.png'),'Resolution',150);
movie=VideoWriter(fullfile(outdir,'hefting_presets_preview.mp4'),'MPEG-4');
movie.FrameRate=10;movie.Quality=90;open(movie);
movieCleanup=onCleanup(@()close(movie));
gifPath=fullfile(outdir,'hefting_presets_preview.gif');
total=max([presets.duration_s]);
for frame=0:round(total*10)
    t=frame/10;
    for k=1:4,update(k,min(round(t/dt)+1,numel(presets(k).time_s)));end
    drawnow;im=getframe(f);writeVideo(movie,im);
    [a,map]=rgb2ind(im.cdata,128);
    if frame==0,imwrite(a,map,gifPath,'gif','LoopCount',inf,'DelayTime',.1);
    else,imwrite(a,map,gifPath,'gif','WriteMode','append','DelayTime',.1);end
end
clear movieCleanup;
writeText(fullfile(outdir,'说明.txt'),sprintf([ ...
    '这是 MATLAB 生成的原装夹爪几何预览；没有连接或驱动机械臂。\n' ...
    '四组动作均固定底座和夹爪，起点停留1秒、中间到位停留1秒、最终停留2秒。\n' ...
    '轨迹间隔50ms；动画10帧/秒，按实际设计时长播放。\n' ...
    '1. 小臂轻抬：肘关节向上8度再返回，8秒。\n' ...
    '2. 慢快双节奏：同样8度幅度，分别用2秒及1.4秒完成单程，12.8秒。\n' ...
    '3. 平托前后移：肩肘反向各6度，在前臂方向固定时改变水平伸距，11秒。\n' ...
    '4. 肩肘组合：抬肘8度、肩向后6度、肘回位、肩回位，14秒。\n' ...
    '动画不是载荷辨识结果，不代表实机保持、装配、碰撞和力矩已验证。\n' ...
    '第4轴是夹爪开合，不作为腕部转动。不得直接将CSV/MAT送入研究控制器。\n' ...
    '这些候选尚未经过信息量筛选，不保证能单独辨识三维质心。\n']));
disp(outdir);

    function update(k,ix)
        E=presets(k).elbow_m(ix,:);P=presets(k).tip_m(ix,:);
        set(h(k).arm,'XData',[0 E(1) P(1)],'YData',[0 E(2) P(2)]);
        set(h(k).tip,'XData',P(1),'YData',P(2));
        u=(P-E)/norm(P-E);v=[-u(2) u(1)];
        jaw=[P-.019*u+.009*v;P+.005*v;nan nan;P-.019*u-.009*v;P-.005*v];
        set(h(k).jaw,'XData',jaw(:,1),'YData',jaw(:,2));
        q=presets(k).wire_joint_deg(ix,:);
        if presets(k).phase(ix)=="hold",word='到位停留';else,word='平滑运动';end
        set(h(k).status,'String',sprintf('%s   %.1f / %.1f s',word,presets(k).time_s(ix),presets(k).duration_s));
        set(h(k).angles,'String',sprintf('肩 %+.1f°   肘 %.1f°   夹爪固定',q(2),q(3)));
    end
end

function [t,q,phase]=plan(W,durations,dt)
q=repmat(W(1,:),round(1/dt)+1,1);phase=repmat("hold",size(q,1),1);
for j=2:size(W,1)
    n=round(durations(j-1)/dt);u=(1:n)'/n;b=10*u.^3-15*u.^4+6*u.^5;
    q=[q;W(j-1,:)+b.*(W(j,:)-W(j-1,:))]; %#ok<AGROW>
    phase=[phase;repmat("move",n,1)]; %#ok<AGROW>
    hold_s=1+(j==size(W,1));nh=round(hold_s/dt);
    q=[q;repmat(W(j,:),nh,1)];phase=[phase;repmat("hold",nh,1)]; %#ok<AGROW>
end
t=(0:size(q,1)-1)'*dt;
end
function [E,P]=geometry(q)
s=deg2rad(q(:,2));e=deg2rad(q(:,3));
l2=hypot(.23682,.030);l3=hypot(.28015,.00173);a=atan2(.030,.23682);
E=[l2*sin(s+a),l2*cos(s+a)];P=E+[l3*sin(s+e),l3*cos(s+e)];
end
function writeText(path,text)
fid=fopen(path,'w','n','UTF-8');assert(fid>0);c=onCleanup(@()fclose(fid));fprintf(fid,'%s',text);
end
