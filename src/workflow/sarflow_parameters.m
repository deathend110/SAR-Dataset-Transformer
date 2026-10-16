function out = sarflow_parameters(value)
%SARFLOW_PARAMETERS 只提取实际计算参数，不包含路径、版本、时间或来源记录。
columns=["Q","QHigh","QLow","STRdB","FrOverBr","FaOverBa","Phi0","ParameterKey"];
if istable(value)
    out=value(:,columns(ismember(columns,string(value.Properties.VariableNames))));return;
end
out=struct();
if ~isstruct(value),return;end
names=[columns,"sampling_mode","dataset_names","scene_names", ...
    "low_percentile","high_percentile","roi_size","energy_buffer","nyquist_margin", ...
    "n_frames","step","signal_height","signal_width","patch_size","valid_margin", ...
    "logic_length","block_width","blocks_per_file","stride_frames","sequence_stride_frames", ...
    "hl_pairs","fixed_q_values","STR_grid","fr_grid","fa_grid", ...
    "fine_STR_offsets","fine_frequency_offsets","phi0","search_per_scene","confirm_per_scene", ...
    "fc","B","Fs","prf","R0","C","v","Tp","Ta","nrn","nan","gama","lambda","R_total","A_num","Ba","Bd","Da", ...
    "VMin","VMax","LowPercentile","HighPercentile"];
for name=names
    if isfield(value,name),out.(name)=value.(name);end
end
for name=["search","sequence","imaging","stats","generate","parameters","normalization_protocol"]
    if isfield(value,name),out.(name)=sarflow_parameters(value.(name));end
end
% 旧混合配置未存模式字段；只从实际倍率字段推断，不检查历史版本。
mode="";
if isfield(value,'sampling_mode'),mode=string(value.sampling_mode);
elseif isfield(value,'Q'),mode="fixed_q";
elseif isfield(value,'QHigh'),mode="hlh";
elseif isfield(value,'search')
    if isfield(value.search,'hl_pairs')&&~isfield(value.search,'fixed_q_values'),mode="hlh";
    elseif isfield(value.search,'fixed_q_values')&&~isfield(value.search,'hl_pairs'),mode="fixed_q";end
end
if isfield(value,'parameter_key'),out.ParameterKey=value.parameter_key;end
if mode~=""
    out.sampling_mode=mode;
    if isfield(out,'search')
        ignored='fixed_q_values';if mode=="fixed_q",ignored='hl_pairs';end
        if isfield(out.search,ignored),out.search=rmfield(out.search,ignored);end
    end
    if mode=="fixed_q"&&isfield(out,'energy_buffer'),out=rmfield(out,'energy_buffer');end
end
end
