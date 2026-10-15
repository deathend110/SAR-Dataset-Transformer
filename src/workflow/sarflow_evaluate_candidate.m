function metrics = sarflow_evaluate_candidate(cfg, record, candidate, role)
%EVALUATE_CANDIDATE 按场景与序列恢复；确认仅读取搜索拟合统计。
candidate=candidate(:,["Stage",sarflow_parameter_columns(sarflow_is_fixed(cfg)),"ParameterKey"]);
p=sarflow_paths(cfg);S60=load(cfg.parameter_file_60);
parameters=sarflow_statistics("parameter_struct",candidate);pair=make_range_sft_pair(parameters);
[h,l]=resolve_pair_grids(pair,cfg.sequence,S60,cfg.nyquist_margin);
carriers=[]; % 已完成的候选只读断点，不重复构造大型载波。
metrics=table();
for scene=cfg.dataset_names
    directory=fullfile(p.checkpoints,"search","fits",candidate.ParameterKey,scene);
    if role=="confirm" && ~isfile(fullfile(directory,"fit.mat"))
        error('sarflow:FitMissing','确认前必须完成搜索拟合。');
    end
    fit=sarflow_fit_candidate(cfg,record,candidate,scene);
    rows=record.manifest(record.manifest.Scene==scene & record.manifest.Role==role,:);
    signature=struct("run",record.signature,"candidate",candidate,"role",role,"fit",fit, ...
        "metric_protocol","uint8_actual_crop_v2_positive_inf_psnr");
    path=fullfile(p.checkpoints,role,candidate.ParameterKey,scene+"_metrics.mat");
    state=sarflow_load_state(path,signature,struct("signature",signature,"completed",0,"metrics",table()));
    if state.completed~=height(state.metrics)||state.completed>height(rows)||state.completed<0
        error('sarflow:CheckpointRows','评价断点行数不正确。');
    end
    if state.completed>0 && ~isequaln(state.metrics.SequenceID,rows.SequenceID(1:state.completed))
        error('sarflow:CheckpointOrder','评价断点序列顺序不正确。');
    end
    if state.completed<height(rows)&&isempty(carriers)
        [ch,cl]=sarflow_build_carriers(pair,h,l,S60);
        carriers=struct("H",ch,"L",cl);
    end
    for j=state.completed+1:height(rows)
        signal=sarflow_load_echo_block(rows(j,:),S60,cfg.sequence.block_width);
        % 每条序列的GT在磁盘共享，内存仅保留当前9帧。
        gtpath=fullfile(p.cache,"gt_frames",sprintf('sequence_%06d.mat',rows.SequenceID(j)));
        gs=struct("run",record.signature,"row",rows(j,:),"stats",fit.gt);
        cache=sarflow_load_state(gtpath,gs,struct("signature",gs,"frames",[]));
        [lq,gt,frames]=sarflow_render_sequence(signal,S60,pair,cfg,fit.input,fit.gt,carriers,cache.frames);
        if isempty(cache.frames),cache.frames=frames;sarflow_atomic_save(gtpath,struct("state",cache));end
        row=candidate;row.Scene=scene;row.SequenceID=rows.SequenceID(j);row.Role=role;
        row=[row,sarflow_sequence_metrics(lq,gt,cfg,S60)]; %#ok<AGROW>
        if isempty(state.metrics),state.metrics=row;else,state.metrics=[state.metrics;row];end
        if j==1
            % 第一条序列保存LQ/GT上下排列的九帧联系图。
            strip_lq=reshape(permute(lq,[1,2,3]),cfg.sequence.patch_size,[]);
            strip_gt=reshape(permute(gt,[1,2,3]),cfg.sequence.patch_size,[]);
            image_directory=fullfile(p.diagnostics,role,candidate.ParameterKey);
            if ~isfolder(image_directory),mkdir(image_directory);end
            imwrite([strip_lq;strip_gt],fullfile(image_directory,scene+"_contact.png"));
        end
        state.completed=j;sarflow_atomic_save(path,struct("state",state));
        fprintf('%s %s：%d/%d完成。\n',role,scene,j,height(rows));
    end
    if isempty(metrics),metrics=state.metrics;else,metrics=[metrics;state.metrics];end %#ok<AGROW>
end
end
