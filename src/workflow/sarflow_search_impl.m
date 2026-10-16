function locked = sarflow_search_impl(cfg)
%RUN_RANGE_2DSFT_SEARCH 完成所有粗细候选后才锁定每个倍率组的参数。
if nargin==0,cfg=range_2dsft_config();end
directory_guard=setup_range_2dsft_paths(cfg); %#ok<NASGU>
record=sarflow_prepare_run(cfg);p=sarflow_paths(cfg);
session=SarflowSearchSession(cfg); % 跨粗细网格与倍率组共享，函数退出即释放。
S60=load(cfg.parameter_file_60);fixed=sarflow_is_fixed(cfg);
if fixed,pairs=[cfg.search.fixed_q_values(:),zeros(numel(cfg.search.fixed_q_values),1)];
else,pairs=cfg.search.hl_pairs;end
all_coarse=table();fine=table();
for k=1:size(pairs,1)
    grid=sarflow_candidate_grid(cfg,S60,pairs(k,1),pairs(k,2));
    rows=sarflow_run_grid(cfg,record,grid,"coarse_pair_"+k,session);
    ranked=sarflow_rank_candidates(rows);anchor=ranked(1,:);
    refined=sarflow_candidate_grid(cfg,S60,pairs(k,1),pairs(k,2),anchor);
    refined=refined(~ismember(refined.ParameterKey,grid.ParameterKey),:);
    if isempty(all_coarse),all_coarse=rows;else,all_coarse=[all_coarse;rows];end %#ok<AGROW>
    if ~isempty(refined)
        if isempty(fine),fine=refined;else,fine=[fine;refined];end %#ok<AGROW>
    end
end
metrics=all_coarse;
if ~isempty(fine)
    metrics=[metrics;sarflow_run_grid(cfg,record,fine,"fine",session)];
end
locked=table();rankings=table();
for k=1:size(pairs,1)
    if fixed,rows=metrics(metrics.Q==pairs(k,1),:);
    else,rows=metrics(metrics.QHigh==pairs(k,1)&metrics.QLow==pairs(k,2),:);end
    ranked=sarflow_rank_candidates(rows);
    if isempty(locked),locked=ranked(1,:);rankings=ranked;
    else,locked=[locked;ranked(1,:)];rankings=[rankings;ranked];end %#ok<AGROW>
end
% CSV是可读副本；MAT和完整运行签名是下游读取依据。
sarflow_locked_contacts(cfg,record,locked,session);
sarflow_atomic_save(p.lock,struct("locked",locked,"rankings",rankings,"record",record,"complete",true, ...
    "metric_protocol","uint8_actual_crop_v2_positive_inf_psnr"));
writetable(locked,fullfile(p.search,"locked_parameters.csv"));
writetable(rankings,fullfile(p.search,"candidate_rankings.csv"));
sarflow_atomic_save(fullfile(p.search,"runtime.mat"),struct("runtime",session.snapshot()));
fprintf('粗细搜索全部完成，已锁定%d组参数。\n',height(locked));
end
