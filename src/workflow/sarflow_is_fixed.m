function fixed = sarflow_is_fixed(cfg)
%SARFLOW_IS_FIXED 模式只决定采集和统计口径，不改变九帧几何协议。
mode=string(cfg.sampling_mode);
if ~isscalar(mode)||~ismember(mode,["hlh","fixed_q"])
    error('sarflow:SamplingMode','sampling_mode必须为hlh或fixed_q。');
end
fixed=mode=="fixed_q";
end
