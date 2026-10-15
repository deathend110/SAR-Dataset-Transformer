function locked = sarflow_read_lock(cfg, record)
%READ_LOCK 不接受孤立CSV或未完成搜索的参数。
p=sarflow_paths(cfg);
if ~isfile(p.lock),error('sarflow:LockMissing','请先完成search阶段。');end
x=load(p.lock);
if ~isfield(x,'complete')||~isequal(x.complete,true)||~isfield(x,'record')|| ...
        ~isequaln(x.record,record)||~isfield(x,'locked')||height(x.locked)~=size(cfg.search.hl_pairs,1)
    error('sarflow:LockMismatch','锁定结果未完成或不属于当前运行。');
end
locked=x.locked;
if ~isequaln([locked.QHigh,locked.QLow],cfg.search.hl_pairs)
    error('sarflow:LockedPairs','锁定倍率顺序或数量不正确。');
end
end
