function sarflow_locked_contacts(cfg,record,locked,session)
%SARFLOW_LOCKED_CONTACTS 完整搜索锁定后，每场景仅为胜出候选补代表图。
p=sarflow_paths(cfg);S60=load(cfg.parameter_file_60);
for k=1:height(locked)
    candidate=locked(k,:);
    candidate=candidate(:,["Stage",sarflow_parameter_columns(sarflow_is_fixed(cfg)),"ParameterKey"]);
    carriers=[];
    for scene=cfg.dataset_names
        path=fullfile(p.diagnostics,"search",candidate.ParameterKey,scene+"_contact.png");
        if isfile(path),continue;end % 旧完整代表图无需重写。
        fit=sarflow_fit_candidate(cfg,record,candidate,scene,session);
        if isempty(carriers)
            pair=make_range_sft_pair(sarflow_statistics("parameter_struct",candidate));
            [h,l]=resolve_pair_grids(pair,cfg.sequence,S60,cfg.nyquist_margin);
            [ch,cl]=sarflow_build_carriers(pair,h,l,S60);session.countCarrier();
            carriers=struct("H",ch,"L",cl);
        end
        rows=record.manifest(record.manifest.Scene==scene & record.manifest.Role=="search",:);
        row=rows(1,:);
        result=sarflow_search_scene(cfg,row,S60,pair,carriers,session,false);
        lq=sarflow_normalize_rois(result.rois{1},fit.input,cfg.sequence.patch_size);
        gt=sarflow_search_gt_frames(cfg,record,row,S60,fit.gt,session);
        sarflow_write_contact(cfg,"search",candidate.ParameterKey,scene,lq,gt);
    end
end
end
