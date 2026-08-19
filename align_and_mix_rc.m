function [RC_mix, info] = align_and_mix_rc(RC_H, RC_L, mode_mask, buffer)
%ALIGN_AND_MIX_RC 用两个边界的汇总功率估计单一gamma并混合H/L。
if ~isequal(size(RC_H), size(RC_L))
    error('rangeSFT:RCSizeMismatch', 'H/L RC尺寸不一致。');
end
mode_mask = logical(mode_mask(:).');
if numel(mode_mask) ~= size(RC_H, 2)
    error('rangeSFT:RCMaskLength', ...
        'H-L-H掩膜长度必须等于RC方位列数。');
end
boundaries = find(diff(mode_mask) ~= 0);
if numel(boundaries) ~= 2
    error('rangeSFT:RCBoundaryCount', ...
        '连续H-L-H块必须包含两个边界。');
end

power_h = zeros(numel(boundaries), 1);
power_l = zeros(numel(boundaries), 1);
for idx = 1:numel(boundaries)
    boundary = boundaries(idx);
    left = max(1, boundary-buffer+1):boundary;
    right = boundary+1:min(size(RC_H, 2), boundary+buffer);
    if mode_mask(boundary)
        h_indices = left;
        l_indices = right;
    else
        l_indices = left;
        h_indices = right;
    end
    power_h(idx) = mean(abs(RC_H(:, h_indices)).^2, 'all');
    power_l(idx) = mean(abs(RC_L(:, l_indices)).^2, 'all');
end

pooled_h = mean(power_h);
pooled_l = mean(power_l);
if ~isfinite(pooled_h) || ~isfinite(pooled_l) || ...
        pooled_h < 0 || pooled_l < 0
    error('rangeSFT:RCPower', 'H/L边界功率包含无效值。');
end
if pooled_h <= 1e-12
    scale_factor = 1;
else
    scale_factor = sqrt((pooled_l + eps) / (pooled_h + eps));
end

RC_H_aligned = RC_H * scale_factor;
RC_mix = zeros(size(RC_H), 'like', RC_H);
RC_mix(:, mode_mask) = RC_H_aligned(:, mode_mask);
RC_mix(:, ~mode_mask) = RC_L(:, ~mode_mask);
info = struct( ...
    "boundaries", boundaries, ...
    "scale_factor", scale_factor, ...
    "power_H", pooled_h, ...
    "power_L", pooled_l, ...
    "boundary_jump_db", 10 * log10( ...
    (pooled_h * scale_factor ^ 2 + eps) / (pooled_l + eps)));
end
