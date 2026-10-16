function stats = sarflow_fit_gt(cfg, record, scene, session)
%FIT_GT GT仅由搜索样本拟合；场景完成后提交统计，不写像素chunk。
if nargin<4,session=SarflowSearchSession(cfg);end
p=sarflow_paths(cfg);
rows=record.manifest(record.manifest.Scene==scene & record.manifest.Role=="search",:);
path=fullfile(p.checkpoints,"search","gt",scene,"state.mat");
state=sarflow_load_state(path,struct("parameters",sarflow_parameters(cfg),"completed",0,"stats",struct()));
sarflow_check_parameters(sarflow_state_parameters(state),cfg,"GT统计");
if ~isempty(fieldnames(state.stats)),stats=state.stats;return;end
% 旧版未完成的场景从头拟合，保留旧chunk和断点，不将其当作完整结果。
S60=load(cfg.parameter_file_60);s=cfg.sequence;n=height(rows);
values=zeros(n*s.roi_size^2*s.n_frames,1,'single');rois=cell(n,1);cursor=0;
for j=1:n
    signal=session.block(rows(j,:),S60,s.block_width);
    for k=1:s.n_frames
        roi=generate_gt_image(signal(:,sarflow_frame_columns(s,k)),S60,s.roi_size);
        if k==1,images=zeros(s.roi_size,s.roi_size,s.n_frames,'like',roi);end
        images(:,:,k)=roi;
        values(cursor+(1:numel(roi)))=single(roi(:));cursor=cursor+numel(roi);
    end
    rois{j}=images;
end
stats=sarflow_pixel_statistics(values,cfg,"GT",n*s.n_frames,n);
for j=1:n
    frames=zeros(s.patch_size,s.patch_size,s.n_frames,'uint8');
    for k=1:s.n_frames
        frames(:,:,k)=sarflow_normalize_frame(rois{j}(:,:,k),stats,s.patch_size);
    end
    session.rememberGT(rows(j,:),stats,frames);
end
state.stats=stats;state.completed=n;
sarflow_atomic_save(path,struct("state",state));
end
