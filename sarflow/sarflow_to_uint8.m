function output = sarflow_to_uint8(normalized, patch_size)
%TO_UINT8 保持生产的先裁剪、double限幅、四舍五入顺序。
input = crop_center(normalized, patch_size);
input = max(0, min(1, double(input)));
output = uint8(round(input * 255));
end
