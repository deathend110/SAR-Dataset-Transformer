function [lq, gt, gt_cache] = sarflow_render_sequence(signal, S60, pair, cfg, input_stats, gt_stats, carriers, gt_cache)
%RENDER_SEQUENCE 搜索与确认使用正式成像流程；GT缓存只保留一条序列。
mask = sarflow_build_hlh_mask(cfg.sequence);
[RC_mix, ~] = sarflow_mix_sequence_rc(signal, S60, pair, mask.full, ...
    cfg.energy_buffer, carriers.H, carriers.L);
s = cfg.sequence;
lq = zeros(s.patch_size, s.patch_size, s.n_frames, 'uint8');
if isempty(gt_cache), gt_cache = zeros(size(lq), 'uint8'); build_gt = true;
else, build_gt = false; end
for k = 1:s.n_frames
    columns = sarflow_frame_columns(s, k);
    roi = focus_base_rc(RC_mix(:, columns), S60, s.roi_size);
    lq(:,:,k) = sarflow_normalize_frame(roi, input_stats, s.patch_size);
    if build_gt
        roi = generate_gt_image(signal(:, columns), S60, s.roi_size);
        gt_cache(:,:,k) = sarflow_normalize_frame(roi, gt_stats, s.patch_size);
    end
end
gt = gt_cache;
end
