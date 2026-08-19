function signal_up = upsample_range_fft(signal, target_rows)
%UPSAMPLE_RANGE_FFT 沿距离维执行中心频谱补零带限插值。
% target_rows必须不小于输入距离维；IFFT后保留有效倍率幅值补偿。
current_rows = size(signal, 1);
if target_rows < current_rows
    error('rangeSFT:UpsampleSize', ...
        '距离上采样目标尺寸不能小于输入尺寸。');
elseif target_rows == current_rows
    signal_up = signal;
    return;
end

spectrum = fftshift(fft(signal, [], 1), 1);
pad_total = target_rows - current_rows;
pad_top = floor(pad_total / 2);
pad_bottom = pad_total - pad_top;
spectrum_up = [ ...
    zeros(pad_top, size(signal, 2), 'like', spectrum); ...
    spectrum; ...
    zeros(pad_bottom, size(signal, 2), 'like', spectrum)];
signal_up = ifft(ifftshift(spectrum_up, 1), [], 1) ...
    * (target_rows / current_rows);
end
