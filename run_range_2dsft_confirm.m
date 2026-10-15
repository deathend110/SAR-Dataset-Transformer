function summary = run_range_2dsft_confirm(cfg)
%RUN_RANGE_2DSFT_CONFIRM 独立轨迹仅报告，不修改锁定参数。
if nargin==0,cfg=range_2dsft_config();end
sarflow.setup(cfg);record=sarflow.prepare_run(cfg);locked=sarflow.read_lock(cfg,record);
metrics=table();
for k=1:height(locked)
    rows=sarflow.evaluate_candidate(cfg,record,locked(k,:),"confirm");
    if isempty(metrics),metrics=rows;else,metrics=[metrics;rows];end %#ok<AGROW>
end
summary=sarflow.rank_candidates(metrics);
% 输出按倍率组对齐的差异，不用确认排名重新选参数。
summary=sortrows(summary,["QHigh","QLow"]);
for k=1:height(summary)
    idx=find(locked.ParameterKey==summary.ParameterKey(k));
    summary.SearchMeanSSIM(k)=locked.MeanSSIM(idx);
    summary.DeltaSSIM(k)=summary.MeanSSIM(k)-locked.MeanSSIM(idx);
    summary.SearchMeanPSNR(k)=locked.MeanPSNR(idx);
    summary.DeltaPSNR(k)=summary.MeanPSNR(k)-locked.MeanPSNR(idx);
end
summary=removevars(summary,'Rank');
p=sarflow.paths(cfg);
sarflow.atomic_save(fullfile(p.search,"confirmation.mat"), ...
    struct("summary",summary,"metrics",metrics,"record",record,"locked",locked,"complete",true));
writetable(summary,fullfile(p.search,"confirmation.csv"));
fprintf('独立确认完成；结果不参与选优，不构成恢复模型测试集。\n');
end
