function image_roi = generate_gt_image(signal, S60, roi_size)
%GENERATE_GT_IMAGE 对未量化60MHz复回波执行标准成像。
% GT不经过SFT、1-bit量化、上采样或H/L混合。
RC_gt = Range_Compress(signal, S60.fc, S60.tnrn, S60.gama, ...
    S60.R0, S60.C, S60.Fs, S60.Tp);
image_roi = focus_base_rc(RC_gt, S60, roi_size);
end
