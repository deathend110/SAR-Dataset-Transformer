function threshold = build_2dsft_threshold(signal_up, grid, parameters, S60)
%BUILD_2DSFT_THRESHOLD 在上采样网格上构造二维单频复SFT阈值。
% fast-time对应距离维，slow-time对应方位维；两方向相位相加后取复指数。
sigma_hat = sqrt(2 / pi) * mean(abs(signal_up(:)));
amplitude = sigma_hat / (10 ^ (parameters.STR_dB / 20));
fr_hz = parameters.fr_over_Br * S60.B;
fa_hz = parameters.fa_over_Ba * resolve_azimuth_bandwidth(S60);

fast_time = ((0:size(signal_up, 1)-1).' ...
    - floor(size(signal_up, 1) / 2)) / grid.Fs_up;
slow_time = ((0:size(signal_up, 2)-1) ...
    - floor(size(signal_up, 2) / 2)) / grid.PRF_up;
phase_range = 2 * pi * fr_hz * fast_time;
phase_azimuth = 2 * pi * fa_hz * slow_time;
threshold = amplitude * exp(1i * ...
    (phase_range + phase_azimuth + parameters.phi0));
end
