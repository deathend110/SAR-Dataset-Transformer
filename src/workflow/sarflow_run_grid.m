function metrics = sarflow_run_grid(cfg, record, candidates, label)
%RUN_GRID 每个候选提交汇总；内部仍按场景和序列保存细粒度断点。
p=sarflow_paths(cfg);path=fullfile(p.checkpoints,"search",label+".mat");
signature=struct("run",record.signature,"candidates",candidates, ...
    "metric_protocol","uint8_actual_crop_v2_positive_inf_psnr");
state=sarflow_load_state(path,signature,struct("signature",signature,"completed",0,"metrics",table()));
if state.completed<0||state.completed>height(candidates)
    error('sarflow:GridCheckpoint','候选进度无效。');
end
for k=state.completed+1:height(candidates)
    fprintf('%s 候选 %d/%d：%s\n',label,k,height(candidates),candidates.ParameterKey(k));
    rows=sarflow_evaluate_candidate(cfg,record,candidates(k,:),"search");
    if isempty(state.metrics),state.metrics=rows;else,state.metrics=[state.metrics;rows];end
    state.completed=k;sarflow_atomic_save(path,struct("state",state));
end
metrics=state.metrics;
end
