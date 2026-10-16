function metrics = sarflow_evaluate_candidate(cfg,record,candidate,role,session)
%EVALUATE_CANDIDATE 候选×场景提交；拟合和评价共享一次成像的ROI。
if nargin<5,session=SarflowSearchSession(cfg);end
candidate=candidate(:,["Stage",sarflow_parameter_columns(sarflow_is_fixed(cfg)),"ParameterKey"]);
p=sarflow_paths(cfg);S60=load(cfg.parameter_file_60);
pair=make_range_sft_pair(sarflow_statistics("parameter_struct",candidate));
[h,l]=resolve_pair_grids(pair,cfg.sequence,S60,cfg.nyquist_margin);
carriers=[];metrics=table();
for scene=cfg.dataset_names
    rows=record.manifest(record.manifest.Scene==scene & record.manifest.Role==role,:);
    fitpath=fullfile(p.checkpoints,"search","fits",candidate.ParameterKey,scene,"fit.mat");
    fs=struct("run",record.signature,"candidate",candidate,"scene",scene);
    fitted=sarflow_load_state(fitpath,fs,struct("signature",fs,"fit",struct()));
    need_fit=isempty(fieldnames(fitted.fit));prepared=[];
    if role=="confirm"&&need_fit
        error('sarflow:FitMissing','确认前必须完成搜索拟合。');
    end
    if need_fit
        % GT只读取搜索清单；先准备一次，评价时直接使用驻留uint8帧。
        sarflow_fit_gt(cfg,record,scene,session);
        if isempty(carriers)
            [ch,cl]=sarflow_build_carriers(pair,h,l,S60);session.countCarrier();
            carriers=struct("H",ch,"L",cl);
        end
        prepared=sarflow_search_scene(cfg,rows,S60,pair,carriers,session,true);
        fit=sarflow_fit_candidate(cfg,record,candidate,scene,session,prepared);
    else
        fit=fitted.fit;
    end
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
    if state.completed<height(rows)
        if isempty(carriers)
            [ch,cl]=sarflow_build_carriers(pair,h,l,S60);session.countCarrier();
            carriers=struct("H",ch,"L",cl);
        end
        if isempty(prepared)
            prepared=sarflow_search_scene(cfg,rows,S60,pair,carriers,session,false);
        end
        % 旧版场景内部分进度允许重算，完整场景原样复用；不改动旧像素chunk。
        scene_metrics=table();
        for j=1:height(rows)
            lq=sarflow_normalize_rois(prepared.rois{j},fit.input,cfg.sequence.patch_size);
            gt=sarflow_search_gt_frames(cfg,record,rows(j,:),S60,fit.gt,session);
            row=candidate;row.Scene=scene;row.SequenceID=rows.SequenceID(j);row.Role=role;
            row=[row,sarflow_sequence_metrics(lq,gt,cfg,S60)]; %#ok<AGROW>
            if isempty(scene_metrics),scene_metrics=row;else,scene_metrics=[scene_metrics;row];end %#ok<AGROW>
            if role=="confirm"&&j==1
                sarflow_write_contact(cfg,role,candidate.ParameterKey,scene,lq,gt);
            end
        end
        state.metrics=scene_metrics;state.completed=height(rows);
        sarflow_atomic_save(path,struct("state",state));
        fprintf('%s %s：场景%d条序列完成并提交。\n',role,scene,height(rows));
    end
    clear prepared
    if isempty(metrics),metrics=state.metrics;else,metrics=[metrics;state.metrics];end %#ok<AGROW>
end
end
