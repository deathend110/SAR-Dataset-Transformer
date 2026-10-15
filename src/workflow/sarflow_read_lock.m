function locked = sarflow_read_lock(cfg, record)
%READ_LOCK 不接受孤立CSV或未完成搜索的参数。
p=sarflow_paths(cfg);
if ~isfile(p.lock),error('sarflow:LockMissing','请先完成search阶段。');end
x=load(p.lock);fixed=sarflow_is_fixed(cfg);
if fixed,count=numel(cfg.search.fixed_q_values);else,count=size(cfg.search.hl_pairs,1);end
if ~isfield(x,'metric_protocol')||string(x.metric_protocol)~="uint8_actual_crop_v2_positive_inf_psnr"
    error('sarflow:LockMetricProtocol','锁定参数使用旧指标口径，请先按修正后的裁剪坐标完成search阶段。');
end
if ~isfield(x,'complete')||~isequal(x.complete,true)||~isfield(x,'record')|| ...
        ~isequaln(x.record,record)||~isfield(x,'locked')||height(x.locked)~=count
    error('sarflow:LockMismatch','锁定结果未完成或不属于当前运行。');
end
locked=x.locked;
if fixed,matched=ismember("Q",string(locked.Properties.VariableNames))&&isequaln(locked.Q,cfg.search.fixed_q_values(:));
else,matched=isequaln([locked.QHigh,locked.QLow],cfg.search.hl_pairs);end
if ~matched
    error('sarflow:LockedPairs','锁定倍率顺序或数量不正确。');
end
end
