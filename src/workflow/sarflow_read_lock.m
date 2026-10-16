function locked = sarflow_read_lock(cfg, ~)
%READ_LOCK 只读取已完成的参数表，不比较运行记录或历史指标版本。
p=sarflow_paths(cfg);
if ~isfile(p.lock),error('sarflow:LockMissing','请先完成search阶段。');end
x=load(p.lock);fixed=sarflow_is_fixed(cfg);
if ~isfield(x,'complete')||~isequal(x.complete,true)||~isfield(x,'locked')
    error('sarflow:LockMismatch','锁定参数尚未完成。');
end
locked=x.locked;
if fixed
    expected=table(cfg.search.fixed_q_values(:),'VariableNames',{'Q'});
else
    expected=array2table(cfg.search.hl_pairs,'VariableNames',{'QHigh','QLow'});
end
if height(locked)~=height(expected)
    error('sarflow:ParameterMismatch','锁定倍率组数不符：原值=%d；当前值=%d。',height(locked),height(expected));
end
sarflow_check_parameters(locked,expected,"锁定参数");
required=[sarflow_parameter_columns(fixed),"ParameterKey"];
missing=required(~ismember(required,string(locked.Properties.VariableNames)));
if ~isempty(missing)
    error('sarflow:LockParameters','锁定参数缺少字段：%s。',strjoin(missing,', '));
end
end
