function parameters = sarflow_state_parameters(state)
%SARFLOW_STATE_PARAMETERS 读取旧文件中已有的实际参数，不校验旧封套或版本。
parameters=struct();
if isfield(state,'parameters'),parameters=state.parameters;return;end
if isfield(state,'config')
    parameters=state.config;
    if isfield(parameters,'parameters'),parameters=parameters.parameters;end
    return;
end
if ~isfield(state,'signature'),return;end
old=state.signature;
for name=["candidate","candidates","stats"]
    if isfield(old,name),parameters=old.(name);return;end
end
if isfield(old,'run')&&isfield(old.run,'config'),parameters=old.run.config;
elseif isfield(old,'config'),parameters=old.config;end
end
