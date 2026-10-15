function image_roi = focus_base_rc(RC_base, S60, roi_size)
%FOCUS_BASE_RC 对60MHz基网格RC执行标准成像并裁取线性幅度ROI。
% 流程固定为RCMC→SAR_Imaging→abs→有效ROI→中心裁剪。
if ~isequal(size(RC_base), [S60.nrn, S60.nan])
    error('rangeSFT:FocusRCSize', ...
        '成像RC必须位于FS60基网格。');
end
RCMC_out = RCMC(RC_base, S60.lambda, S60.fnrn, S60.fnan, ...
    S60.R0, S60.C, S60.v);
image_complex = SAR_Imaging(RCMC_out, S60.lambda, S60.Fs, ...
    S60.R0, S60.C, S60.v, S60.tnan, S60.Ta, S60.prf);
row_start = S60.nrn / 2 - S60.R_total / 2 + 1;
row_end = S60.nrn / 2 + S60.R_total / 2;
column_start = S60.nan / 2 - S60.A_num / 2;
column_end = S60.nan / 2 + S60.A_num / 2 - 1;
full_roi = abs(image_complex(row_start:row_end, ...
    column_start:column_end));
image_roi = crop_center(full_roi, roi_size);
end
