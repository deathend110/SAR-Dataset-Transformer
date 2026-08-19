function output = crop_center(input, target_size)
%CROP_CENTER 从二维输入中心裁取target_size×target_size区域。
row_start = floor((size(input, 1) - target_size) / 2) + 1;
column_start = floor((size(input, 2) - target_size) / 2) + 1;
if row_start < 1 || column_start < 1
    error('rangeSFT:CropCenter', ...
        '中心裁剪尺寸超过输入图像。');
end
output = input(row_start:row_start+target_size-1, ...
    column_start:column_start+target_size-1);
end
