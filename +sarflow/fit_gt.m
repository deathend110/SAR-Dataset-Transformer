function stats = fit_gt(cfg, record, scene)
%FIT_GT GT只用搜索样本拟合，按场景共享；每条序列原子记录进度。
p=sarflow.paths(cfg); directory=fullfile(p.search,"gt",scene);
rows=record.manifest(record.manifest.Scene==scene & record.manifest.Role=="search",:);
signature=struct("run",record.signature,"rows",rows);
path=fullfile(directory,"state.mat");
state=sarflow.load_state(path,signature,struct("signature",signature,"completed",0,"stats",struct()));
if ~isempty(fieldnames(state.stats)),stats=state.stats;return;end
S60=load(cfg.parameter_file_60);s=cfg.sequence;
for j=state.completed+1:height(rows)
    signal=sarflow.load_echo_block(rows(j,:),S60,s.block_width);
    values=zeros(s.roi_size^2*s.n_frames,1,'single');
    for k=1:s.n_frames
        roi=generate_gt_image(signal(:,sarflow.frame_columns(s,k)),S60,s.roi_size);
        values((k-1)*s.roi_size^2+(1:s.roi_size^2))=single(roi(:));
    end
    sarflow.atomic_save(fullfile(directory,sprintf('chunk_%06d.mat',j)),struct("values",values));
    state.completed=j;sarflow.atomic_save(path,struct("state",state));
end
state.stats=sarflow.statistics("calculate_chunk_percentiles",directory, ...
    [cfg.low_percentile,cfg.high_percentile],"GT",height(rows)*s.n_frames, ...
    s.roi_size^2,cfg.stats.memory_gb,height(rows),cfg.stats.in_memory);
sarflow.atomic_save(path,struct("state",state));stats=state.stats;
end
