function output = crop_range_spectrum(input, target_rows)
%CROP_RANGE_SPECTRUM 将上采样距离频谱裁回目标距离网格。
% 只处理距离维；偶数和奇数目标尺寸沿用原中心索引规则。
current_rows = size(input, 1);
if target_rows > current_rows
    error('rangeSFT:CropSize', ...
        '距离频谱裁剪目标不能大于当前尺寸。');
elseif target_rows == current_rows
    output = input;
    return;
end

spectrum = fftshift(fft(input, [], 1), 1);
center = floor(current_rows / 2) + 1;
half_width = floor(target_rows / 2);
if mod(target_rows, 2) == 0
    indices = center-half_width:center+half_width-1;
else
    indices = center-half_width:center+half_width;
end
output = ifft(ifftshift(spectrum(indices, :), 1), [], 1);
end
