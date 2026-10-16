function fit = sarflow_fit_candidate(cfg,record,candidate,scene,session,prepared)
%FIT_CANDIDATE 读取旧完整拟合，或提交当前场景内存ROI的拟合结果。
if nargin<5,session=SarflowSearchSession(cfg);end
p=sarflow_paths(cfg);
path=fullfile(p.checkpoints,"search","fits",candidate.ParameterKey,scene,"fit.mat");
signature=struct("run",record.signature,"candidate",candidate,"scene",scene);
state=sarflow_load_state(path,signature,struct("signature",signature,"fit",struct()));
if ~isempty(fieldnames(state.fit)),fit=state.fit;return;end
rows=record.manifest(record.manifest.Scene==scene & record.manifest.Role=="search",:);
gt=sarflow_fit_gt(cfg,record,scene,session);
if nargin<6
    S60=load(cfg.parameter_file_60);
    pair=make_range_sft_pair(sarflow_statistics("parameter_struct",candidate));
    [h,l]=resolve_pair_grids(pair,cfg.sequence,S60,cfg.nyquist_margin);
    [ch,cl]=sarflow_build_carriers(pair,h,l,S60);session.countCarrier();
    prepared=sarflow_search_scene(cfg,rows,S60,pair,struct("H",ch,"L",cl),session,true);
end
state.fit=struct("input",prepared.input_stats,"gt",gt,"audit",prepared.audit,"search_manifest",rows);
sarflow_atomic_save(path,struct("state",state));fit=state.fit;
end
