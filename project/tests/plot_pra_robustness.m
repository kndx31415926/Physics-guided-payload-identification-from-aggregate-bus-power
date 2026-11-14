function plot_pra_robustness(outdir)
% Standard scientific figure, reading frozen CSV outputs only.
S=readtable(fullfile(outdir,'main_results.csv'),'TextType','string');
methods=["physics_residual_nn","physics_inverse","encoder_plus_power","power_only"];
names={'Physics + residual NN','Physics inverse','Encoder + power NN','Power NN'};
colors=[0 114 178;213 94 0;0 158 115;204 121 167]/255;markers={'o','s','^','d'};
fig=figure('Visible','off','Color','w','Position',[60 60 1500 1050]);
clean=onCleanup(@()close(fig)); %#ok<NASGU>
layout=tiledlayout(fig,2,2,'TileSpacing','compact','Padding','compact');
ax=nexttile(layout);hold(ax,'on');
conditions=["nominal","power_noise_0p09","power_noise_0p15"];
for j=1:4
    plot(ax,[.03 .09 .15],values(S,methods(j),conditions,'mass_mae_g'), ...
        'Color',colors(j,:),'Marker',markers{j},'LineWidth',1.7,'MarkerSize',6,'DisplayName',names{j});
end
format_mass(ax,'(a) Random power noise');xticks(ax,[.03 .09 .15]);
xlabel(ax,'Power white-noise standard deviation (W)');legend(ax,'Location','northwest','Box','off');
ax=nexttile(layout);hold(ax,'on');
conditions=["power_bias_minus_0p10","power_bias_plus_0p10","power_gain_0p97","power_gain_1p03"];
for j=1:4
    scatter(ax,(1:4)+(j-2.5)*.12,values(S,methods(j),conditions,'mass_mae_g'), ...
        50,colors(j,:),markers{j},'filled');
end
format_mass(ax,'(b) Systematic power bias and gain');xlim(ax,[.5 4.5]);xticks(ax,1:4);
xticklabels(ax,{'Offset -0.10 W','Offset +0.10 W','Gain -3%','Gain +3%'});
xlabel(ax,'Systematic power measurement error');
ax=nexttile(layout);hold(ax,'on');conditions=["nominal","encoder_2048","encoder_1024"];
for j=1:4
    plot(ax,1:3,values(S,methods(j),conditions,'mass_mae_g'),'Color',colors(j,:), ...
        'Marker',markers{j},'LineWidth',1.7,'MarkerSize',6);
end
format_mass(ax,'(c) Coarsened encoder readout');xlim(ax,[.8 3.2]);xticks(ax,1:3);xticklabels(ax,{'4096 (nominal)','2048','1024'});
xlabel(ax,'Encoder counts per revolution');
ax=nexttile(layout);conditions=["nominal","power_noise_0p09","power_noise_0p15", ...
    "power_bias_minus_0p10","power_bias_plus_0p10","power_gain_0p97","power_gain_1p03", ...
    "encoder_2048","encoder_1024","pitch_bias_minus_tick","pitch_bias_plus_tick","combined"];
labels={'Nominal','Noise 0.09 W','Noise 0.15 W','Offset -0.10 W','Offset +0.10 W', ...
    'Gain -3%','Gain +3%','Encoder 2048/rev','Encoder 1024/rev','Pitch offset -1 tick','Pitch offset +1 tick','Combined stress'};
coverage=100*values(S,"physics_residual_nn",conditions,'accepted_coverage');
barh(ax,1:12,coverage,.65,'FaceColor',colors(1,:),'EdgeColor','none');
set(ax,'YDir','reverse','YTick',1:12,'YTickLabel',labels,'FontSize',10,'Box','off');
xlim(ax,[0 112]);xticks(ax,0:25:100);xlabel(ax,'Accepted estimates (%)');
title(ax,'(d) Physics + residual NN coverage','FontWeight','bold');grid(ax,'on');
for j=1:12,text(ax,coverage(j)+1,j,sprintf('%.1f',coverage(j)),'FontSize',9,'VerticalAlignment','middle');end
title(layout,'Frozen-model measurement robustness on 300 held-out objects','FontWeight','bold','FontSize',16);
exportgraphics(fig,fullfile(outdir,'robustness_four_panel.png'),'Resolution',180);
exportgraphics(fig,fullfile(outdir,'robustness_four_panel.pdf'),'ContentType','vector');
fid=fopen(fullfile(outdir,'FIGURE_CAPTION.txt'),'w','n','UTF-8');cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,['Frozen-model measurement robustness on 300 held-out objects. Panels (a-c) show mass MAE for ' ...
    'three-seed model ensembles (physics inverse is deterministic), after common per-seed output bounds. ' ...
    'MAEs across the three added-noise realizations are averaged with equal weight; noisy observations ' ...
    'and their predictions are not averaged. The mass-error axes are logarithmic. Panel (d) shows the ' ...
    'main model acceptance coverage over the complete planned denominator. The pure physics method ' ...
    'has the same coverage because both methods share the physical-teacher gate. Measurement ' ...
    'bias can be accepted while inaccurate. Encoder coarsening acts on recorded samples; mechanical ' ...
    'dynamics and low-level control are unchanged. Combined stress is 0.15 W total white noise, ' ...
    '+0.10 W power offset and encoder coarsening to 1024/rev. COM results, raw predictions and paired ' ...
    'object-bootstrap contrasts are reported separately. These conditions reuse the same objects; ' ...
    'repeated noise realizations are not independent objects.\n']);
fprintf('PRA robustness figure saved: %s\n',outdir);
end
function v=values(S,method,conditions,key)
v=zeros(size(conditions));
for k=1:numel(conditions)
    chosen=S.method==method&S.condition==conditions(k);assert(sum(chosen)==1);v(k)=S.(key)(chosen);
end
end
function format_mass(ax,heading)
title(ax,heading,'FontWeight','bold');set(ax,'YScale','log','FontSize',11,'Box','off');ylim(ax,[.25 40]);
ylabel(ax,'Mass MAE (g; logarithmic scale)');grid(ax,'on');
end
