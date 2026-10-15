function state = sarflow_load_state(path, signature, initial)
%LOAD_STATE 严格比较完整签名，拒绝配置不一致的断点。
state=initial;
if isfile(path)
    x=load(path,'state');
    if ~isfield(x,'state')||~isfield(x.state,'signature')||~isequaln(x.state.signature,signature)
        error('sarflow:CheckpointMismatch','checkpoint签名不一致：%s',path);
    end
    state=x.state;
end
end
