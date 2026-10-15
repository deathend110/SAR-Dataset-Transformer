function out = sarflow_sequence_metrics(lq, gt, cfg, S60)
%SEQUENCE_METRICS 主指标用uint8；结构指标使用[0,1]，避免动态范围混用。
s=cfg.sequence;fixed=sarflow_is_fixed(cfg);
if ~fixed
    if nargin<4,S60=load(cfg.parameter_file_60);end
    mask=sarflow_build_hlh_mask(s);
    [~,roi_columns]=sar_image_roi_indices(S60,s.roi_size);
    patch_start=floor((numel(roi_columns)-s.patch_size)/2)+1;
    patch_columns=roi_columns(patch_start+(0:s.patch_size-1));
end
ps=zeros(s.n_frames,1);ss=ps;ls=nan(s.n_frames,1);gr=ps;br=ps;
boundary=zeros(0,1); overlap=zeros(s.n_frames-1,1);
a=double(lq)/255;b=double(gt)/255;
for k=1:s.n_frames
    ps(k)=psnr(lq(:,:,k),gt(:,:,k));ss(k)=ssim(lq(:,:,k),gt(:,:,k));
    edges=[];
    if ~fixed
        columns=sarflow_frame_columns(s,k);
        hmask=mask.full(columns(patch_columns));
        if sum(~hmask)>=11,ls(k)=ssim(lq(:,~hmask,k),gt(:,~hmask,k));end
        edges=find(diff(hmask)~=0);
    end
    [ax,ay]=gradient(a(:,:,k));[bx,by]=gradient(b(:,:,k));
    gr(k)=sqrt(mean((hypot(ax,ay)-hypot(bx,by)).^2,'all'));
    target=b(:,:,k);image=a(:,:,k);bright=target>=prctile(target(:),99);
    br(k)=mean(abs(image(bright)-target(bright)));
    for e=edges
        boundary(end+1,1)=mean(abs(image(:,e+1)-image(:,e)))- ...
            mean(abs(target(:,e+1)-target(:,e))); %#ok<AGROW>
    end
    if k<s.n_frames
        width=s.patch_size-s.step;
        overlap(k)=ssim(b(:,end-width+1:end,k),b(:,1:width,k+1),'DynamicRange',1)- ...
            ssim(a(:,end-width+1:end,k),a(:,1:width,k+1),'DynamicRange',1);
    end
end
if isempty(boundary)
    if fixed,boundary=NaN;else,boundary=0;end
end
out=table(mean(ss),mean(ls,'omitnan'),min(ss),mean(ps),mean(gr),mean(br), ...
    mean(boundary),mean(overlap),'VariableNames', ...
    ["MeanSSIM","LRegionSSIM","WorstSSIM","MeanPSNR","GradientRMSE", ...
    "BrightScattererError","BoundaryGradientExcess","OverlapExcessSSIMLoss"]);
applicable=1:size(out,2);
if fixed,applicable([2,7])=[];end
% 完全一致时PSNR=+Inf是合法值；其他指标仍须有限。
applicable(applicable==4)=[];
if any(~isfinite(out{:,applicable}))||isnan(out.MeanPSNR)||out.MeanPSNR==-Inf
    error('sarflow:NonfiniteMetrics','评价指标无效。');
end
end
