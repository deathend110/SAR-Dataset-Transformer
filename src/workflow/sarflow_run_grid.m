function metrics = sarflow_run_grid(cfg,record,candidates,label,session)
%RUN_GRID 候选进度只保存完成位置；详细指标从场景断点组装。
if nargin<5,session=SarflowSearchSession(cfg);end
p=sarflow_paths(cfg);path=fullfile(p.checkpoints,"search",label+".mat");
signature=struct("run",record.signature,"candidates",candidates, ...
    "metric_protocol","uint8_actual_crop_v2_positive_inf_psnr");
state=sarflow_load_state(path,signature,struct("signature",signature,"completed",0));
if state.completed<0||state.completed>height(candidates)||mod(state.completed,1)~=0
    error('sarflow:GridCheckpoint','候选进度无效。');
end
metrics=table();start=1;
% 旧版完整候选汇总可直接读取；下一次提交即切换为小型索引，不删除旧产物。
if isfield(state,'metrics')&&state.completed>0
    metrics=state.metrics;start=state.completed+1;
end
completed=state.completed;
for k=start:height(candidates)
    fprintf('%s 候选 %d/%d：%s\n',label,k,height(candidates),candidates.ParameterKey(k));
    rows=sarflow_evaluate_candidate(cfg,record,candidates(k,:),"search",session);
    if isempty(metrics),metrics=rows;else,metrics=[metrics;rows];end %#ok<AGROW>
    if k>completed
        state=struct("signature",signature,"completed",k);
        sarflow_atomic_save(path,struct("state",state));
    end
end
end
