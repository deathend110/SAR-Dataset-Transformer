function result = sarflow_search_scene(cfg,rows,S60,pair,carriers,session,need_fit)
%SARFLOW_SEARCH_SCENE 每条连续回波只采集一次RC，保留当前场景的混合ROI。
% H/L纯分支像素仅在拟合时等权汇集；不将所有候选图像常驻内存。
s=cfg.sequence;n=height(rows);fixed=sarflow_is_fixed(cfg);
[h,l]=resolve_pair_grids(pair,s,S60,cfg.nyquist_margin);
branches=2;modality="JointHL";
if fixed,branches=1;modality="FixedQ";end
values=[];
if need_fit,values=zeros(n*s.n_frames*s.roi_size^2*branches,1,'single');end
rois=cell(n,1);scales=nan(n,1);jumps=scales;cursor=0;
for j=1:n
    signal=session.block(rows(j,:),S60,s.block_width);
    pre=session.upsampled(rows(j,:),signal,h.upsampled_size(1));other=[];
    if ~fixed,other=session.upsampled(rows(j,:),signal,l.upsampled_size(1));end
    [rc,info,first,second]=sarflow_sequence_rc(signal,S60,pair,s,cfg.energy_buffer, ...
        carriers.H,carriers.L,pre,other);
    session.countRC(branches);
    clear signal pre other
    scales(j)=info.scale_factor;jumps(j)=info.boundary_jump_db;
    for k=1:s.n_frames
        columns=sarflow_frame_columns(s,k);
        roi=focus_base_rc(rc(:,columns),S60,s.roi_size);
        % 评价ROI保留原始计算类型，避免double回波提前转single改变uint8。
        if k==1,images=zeros(s.roi_size,s.roi_size,s.n_frames,'like',roi);end
        images(:,:,k)=roi;
        if need_fit
            if fixed,pixels=single(roi(:));
            else
                hi=focus_base_rc(first(:,columns),S60,s.roi_size);
                lo=focus_base_rc(second(:,columns),S60,s.roi_size);
                pixels=[single(hi(:));single(lo(:))];
            end
            values(cursor+(1:numel(pixels)))=pixels;cursor=cursor+numel(pixels); %#ok<AGROW> 已按场景全部像素预分配。
        end
    end
    rois{j}=images;
    clear rc first second images
end
input=struct();audit=struct();
if need_fit
    input=sarflow_pixel_statistics(values,cfg,modality,branches*n*s.n_frames,n);
    audit=struct("SequenceCount",n,"FileCount",numel(unique(rows.FilePath)), ...
        "BlocksPerFile",cfg.stats.blocks_per_file,"ScaleFactorMin",min(scales), ...
        "ScaleFactorMean",mean(scales),"ScaleFactorMax",max(scales), ...
        "MaxAbsBoundaryJumpDB",max(abs(jumps)),"CompletedSequences",n);
    if fixed
        audit=rmfield(audit,{'ScaleFactorMin','ScaleFactorMean','ScaleFactorMax','MaxAbsBoundaryJumpDB'});
        audit.SamplingMode="fixed_q";
    elseif any(~isfinite([scales;jumps]))
        error('scenePercentiles:NonfiniteAudit','场景统计审计量中存在非有限值。');
    end
end
result=struct("rois",{rois},"input_stats",input,"audit",audit);
end
