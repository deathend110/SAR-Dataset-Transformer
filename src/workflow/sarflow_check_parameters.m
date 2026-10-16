function sarflow_check_parameters(saved,current,context)
%SARFLOW_CHECK_PARAMETERS 逐项核对实际参数；旧格式未记录的字段不阻断恢复。
if nargin<3,context="恢复参数";end
saved=sarflow_parameters(saved);current=sarflow_parameters(current);
if istable(saved)&&istable(current)
    if ismember("Q",string(saved.Properties.VariableNames))~=ismember("Q",string(current.Properties.VariableNames))
        a="hlh";b="hlh";
        if ismember("Q",string(saved.Properties.VariableNames)),a="fixed_q";end
        if ismember("Q",string(current.Properties.VariableNames)),b="fixed_q";end
        mismatch(context+".sampling_mode",a,b);
    end
    names=string(current.Properties.VariableNames);
else
    if ~isstruct(saved)||~isstruct(current),return;end
    names=string(fieldnames(current)).';
end
for name=names
    if istable(saved),present=ismember(name,string(saved.Properties.VariableNames));
    else,present=isfield(saved,name);end
    if ~present,continue;end
    a=saved.(name);b=current.(name);
    if isstruct(a)&&isstruct(b)
        sarflow_check_parameters(a,b,context+"."+name);
    elseif ~isequaln(a,b)
        mismatch(context+"."+name,a,b);
    end
end
end

function mismatch(name,old,new)
error('sarflow:ParameterMismatch','参数%s不符：原值=%s；当前值=%s。',name,describe(old),describe(new));
end

function text=describe(value)
if isnumeric(value)||islogical(value),text=string(mat2str(value));
else,text=join(string(value(:)).',", ");end
end
