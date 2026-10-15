function compatible = sarflow_dataset_compatible(existing, requested)
%SARFLOW_DATASET_COMPATIBLE 相同数据/生产口径可复用，仅来源路径变化不强制重做。
compatible=isequaln(existing,requested);
if compatible,return;end
try
    left=existing;right=requested;
    ignored={'stats_root','normalization_sources','workflow','normalization_snapshot'};
    for k=1:numel(ignored)
        if isfield(left,ignored{k}),left=rmfield(left,ignored{k});end
        if isfield(right,ignored{k}),right=rmfield(right,ignored{k});end
    end
    if isfield(left.normalization_protocol,'workflow')
        left.normalization_protocol=rmfield(left.normalization_protocol,'workflow');
    end
    if isfield(right.normalization_protocol,'workflow')
        right.normalization_protocol=rmfield(right.normalization_protocol,'workflow');
    end
    if ~isequaln(left,right),return;end
    compatible=isequaln(sarflow_normalization_snapshot(existing), ...
        sarflow_normalization_snapshot(requested));
catch
    % 来源缺失或统计已被替换时，无法证明兼容，保留原有拒绝覆盖行为。
    compatible=false;
end
end
