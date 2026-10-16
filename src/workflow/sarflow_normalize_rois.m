function frames = sarflow_normalize_rois(rois,stats,patch_size)
%SARFLOW_NORMALIZE_ROIS 复用正式逐帧裁剪/量化函数，不改变ROI的数据类型。
frames=zeros(patch_size,patch_size,size(rois,3),'uint8');
for k=1:size(rois,3)
    frames(:,:,k)=sarflow_normalize_frame(rois(:,:,k),stats,patch_size);
end
end
