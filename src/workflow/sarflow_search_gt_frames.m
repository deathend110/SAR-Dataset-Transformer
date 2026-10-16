function frames = sarflow_search_gt_frames(cfg,~,row,S60,stats,session)
%SARFLOW_SEARCH_GT_FRAMES 优先复用会话及旧版完整GT缓存，不写逐序列文件。
[frames,found]=session.gt(row,stats);
if found,return;end
p=sarflow_paths(cfg);
path=fullfile(p.cache,"gt_frames",sprintf('sequence_%06d.mat',row.SequenceID));
old=sarflow_load_state(path,struct("parameters",sarflow_parameters(stats),"frames",[]));
sarflow_check_parameters(sarflow_state_parameters(old),stats,"GT归一化");
frames=old.frames;
if isempty(frames)
    s=cfg.sequence;signal=session.block(row,S60,s.block_width);
    frames=zeros(s.patch_size,s.patch_size,s.n_frames,'uint8');
    for k=1:s.n_frames
        roi=generate_gt_image(signal(:,sarflow_frame_columns(s,k)),S60,s.roi_size);
        frames(:,:,k)=sarflow_normalize_frame(roi,stats,s.patch_size);
    end
end
session.rememberGT(row,stats,frames);
end
