function state = sarflow_load_state(path,initial)
%LOAD_STATE 只读取进度，不接收或检查签名、版本与来源信息。
state=initial;
if isfile(path)
    x=load(path,'state');
    if ~isfield(x,'state'),error('sarflow:CheckpointState','检查点缺少state：%s',path);end
    state=x.state;
end
end
