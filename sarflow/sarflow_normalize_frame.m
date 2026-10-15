function output = sarflow_normalize_frame(roi, stats, patch_size)
%NORMALIZE_FRAME 统一600 ROI归一化、512中心裁剪与uint8量化。
if ~all(isfinite([stats.VMin, stats.VMax])) || stats.VMax <= stats.VMin
    error('sarflow:Normalization', '归一化分位数无效。');
end
output = sarflow_to_uint8(minmaxnormalize_image(roi, stats.VMax, stats.VMin), patch_size);
end
