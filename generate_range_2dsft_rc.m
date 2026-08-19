function RC_base = generate_range_2dsft_rc(signal, S60, acquisition)
%GENERATE_RANGE_2DSFT_RC 生成一条采集分支的60MHz基网格距离压缩结果。
% 流程：距离FFT上采样→二维SFT阈值→复1-bit量化→距离压缩→频谱回投影。
grid = resolve_range_grid(acquisition.q_total, size(signal), S60);
signal_up = upsample_range_fft(signal, grid.upsampled_size(1));
threshold = build_2dsft_threshold( ...
    signal_up, grid, acquisition.threshold, S60);
if ~isequal(size(signal_up), size(threshold))
    error('rangeSFT:ThresholdSize', ...
        '回波与二维SFT阈值尺寸不一致。');
end

% 公共量化器直接处理复输入，因此先显式叠加信号和阈值。
channel_1bit = quantize_1bit(signal_up + threshold);
tnrn_up = 2 * S60.R0 / S60.C + ...
    ((0:size(signal_up, 1)-1).' - floor(size(signal_up, 1) / 2)) ...
    / grid.Fs_up;
RC_up = Range_Compress(channel_1bit, S60.fc, tnrn_up, S60.gama, ...
    S60.R0, S60.C, grid.Fs_up, S60.Tp);
RC_base = crop_range_spectrum(RC_up, size(signal, 1));
if ~isequal(size(RC_base), size(signal))
    error('rangeSFT:BaseRCSize', ...
        '距离压缩结果无法投影回60MHz基网格。');
end
end
