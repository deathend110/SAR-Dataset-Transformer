function out = sequence_metrics(lq, gt, cfg)
%SEQUENCE_METRICS 主指标用uint8；结构指标使用[0,1]，避免动态范围混用。
s=cfg.sequence; mask=sarflow.build_hlh_mask(s);
ps=zeros(s.n_frames,1);ss=ps;ls=nan(s.n_frames,1);gr=ps;br=ps;
boundary=zeros(0,1); overlap=zeros(s.n_frames-1,1);
a=double(lq)/255;b=double(gt)/255;
for k=1:s.n_frames
    ps(k)=psnr(lq(:,:,k),gt(:,:,k));ss(k)=ssim(lq(:,:,k),gt(:,:,k));
    columns=sarflow.frame_columns(s,k);
    offset=floor((s.signal_width-s.patch_size)/2);
    hmask=mask.full(columns(offset+(1:s.patch_size)));
    if sum(~hmask)>=11,ls(k)=ssim(lq(:,~hmask,k),gt(:,~hmask,k));end
    [ax,ay]=gradient(a(:,:,k));[bx,by]=gradient(b(:,:,k));
    gr(k)=sqrt(mean((hypot(ax,ay)-hypot(bx,by)).^2,'all'));
    target=b(:,:,k);image=a(:,:,k);bright=target>=prctile(target(:),99);
    br(k)=mean(abs(image(bright)-target(bright)));
    edges=find(diff(hmask)~=0);
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
if isempty(boundary),boundary=0;end
out=table(mean(ss),mean(ls,'omitnan'),min(ss),mean(ps),mean(gr),mean(br), ...
    mean(boundary),mean(overlap),'VariableNames', ...
    ["MeanSSIM","LRegionSSIM","WorstSSIM","MeanPSNR","GradientRMSE", ...
    "BrightScattererError","BoundaryGradientExcess","OverlapExcessSSIMLoss"]);
if any(~isfinite(out{:,1:4}))||any(~isfinite(out{:,5:end}))
    error('sarflow:NonfiniteMetrics','评价指标无效。');
end
end
