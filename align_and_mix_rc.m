function [RC_mix, info] = align_and_mix_rc(RC_H, RC_L, mode_mask, buffer)
%ALIGN_AND_MIX_RC 复用统一gamma估计并完成H/L空间拼接。
info = estimate_rc_alignment(RC_H, RC_L, mode_mask, buffer);
mode_mask = logical(mode_mask(:).');
RC_mix = zeros(size(RC_H), 'like', RC_H);
RC_mix(:, mode_mask) = RC_H(:, mode_mask) * info.scale_factor;
RC_mix(:, ~mode_mask) = RC_L(:, ~mode_mask);
end
