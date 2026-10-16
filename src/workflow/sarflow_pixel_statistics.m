function stats = sarflow_pixel_statistics(values,cfg,modality,image_count,sequence_count)
%SARFLOW_PIXEL_STATISTICS 搜索内存像素池沿用正式统计的single/midpoint协议。
% ChunkCount保留原统计结构，表示逻辑序列块数，不意味着写出了像素文件。
limits=double(prctile(values,[cfg.low_percentile,cfg.high_percentile],Method="midpoint"));
if any(~isfinite(limits))||limits(2)<=limits(1)
    error('scenePercentiles:DegeneratePercentiles','%s分位数范围无效。',modality);
end
stats=struct("Modality",modality,"VMin",limits(1),"VMax",limits(2), ...
    "ImageCount",image_count,"PixelCount",double(numel(values)), ...
    "ChunkCount",sequence_count,"LowPercentile",cfg.low_percentile, ...
    "HighPercentile",cfg.high_percentile,"Method","midpoint_exact_tall","Backend","memory");
end
