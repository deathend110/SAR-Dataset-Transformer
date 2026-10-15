function locked = run_range_2dsft_search(cfg)
%RUN_RANGE_2DSFT_SEARCH 完成所有粗细候选后才锁定每个倍率组的参数。
if nargin==0,cfg=range_2dsft_config();end
sarflow.setup(cfg);record=sarflow.prepare_run(cfg);p=sarflow.paths(cfg);
S60=load(cfg.parameter_file_60);pairs=cfg.search.hl_pairs;
all_coarse=table();fine=table();
for k=1:size(pairs,1)
    grid=sarflow.candidate_grid(cfg,S60,pairs(k,1),pairs(k,2));
    rows=sarflow.run_grid(cfg,record,grid,"coarse_pair_"+k);
    ranked=sarflow.rank_candidates(rows);anchor=ranked(1,:);
    refined=sarflow.candidate_grid(cfg,S60,pairs(k,1),pairs(k,2),anchor);
    refined=refined(~ismember(refined.ParameterKey,grid.ParameterKey),:);
    if isempty(all_coarse),all_coarse=rows;else,all_coarse=[all_coarse;rows];end %#ok<AGROW>
    if ~isempty(refined)
        if isempty(fine),fine=refined;else,fine=[fine;refined];end %#ok<AGROW>
    end
end
metrics=all_coarse;
if ~isempty(fine)
    metrics=[metrics;sarflow.run_grid(cfg,record,fine,"fine")];
end
locked=table();rankings=table();
for k=1:size(pairs,1)
    rows=metrics(metrics.QHigh==pairs(k,1)&metrics.QLow==pairs(k,2),:);
    ranked=sarflow.rank_candidates(rows);
    if isempty(locked),locked=ranked(1,:);rankings=ranked;
    else,locked=[locked;ranked(1,:)];rankings=[rankings;ranked];end %#ok<AGROW>
end
% CSV是可读副本；MAT和完整运行签名是下游读取依据。
sarflow.atomic_save(p.lock,struct("locked",locked,"rankings",rankings,"record",record,"complete",true));
writetable(locked,fullfile(p.search,"locked_parameters.csv"));
writetable(rankings,fullfile(p.search,"candidate_rankings.csv"));
fprintf('粗细搜索全部完成，已锁定%d组参数。\n',height(locked));
end
