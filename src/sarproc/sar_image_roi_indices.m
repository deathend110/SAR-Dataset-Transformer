function [rows, columns] = sar_image_roi_indices(S60, roi_size)
%SAR_IMAGE_ROI_INDICES 共享生产图像的实际裁剪坐标，保留既有PNG位置。
% 距离ROI从+1中心索引起算；方位ROI沿用历史起点，不在此平移旧图像。
if roi_size>S60.R_total||roi_size>S60.A_num
    error('rangeSFT:CropCenter','中心裁剪尺寸超过输入图像。');
end
row_start=S60.nrn/2-S60.R_total/2+1+floor((S60.R_total-roi_size)/2);
column_start=S60.nan/2-S60.A_num/2+floor((S60.A_num-roi_size)/2);
rows=row_start+(0:roi_size-1);
columns=column_start+(0:roi_size-1);
end
