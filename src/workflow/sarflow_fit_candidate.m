function fit = sarflow_fit_candidate(cfg, record, candidate, scene)
%FIT_CANDIDATE 复用正式JointHL统计内核，完成后保存小型拟合结果。
p=sarflow_paths(cfg);directory=fullfile(p.cache,"search","candidates",candidate.ParameterKey,scene);
checkpoint_directory=fullfile(p.checkpoints,"search","fits",candidate.ParameterKey,scene);
path=fullfile(checkpoint_directory,"fit.mat");
signature=struct("run",record.signature,"candidate",candidate,"scene",scene);
state=sarflow_load_state(path,signature,struct("signature",signature,"fit",struct()));
if ~isempty(fieldnames(state.fit)),fit=state.fit;return;end
S60=load(cfg.parameter_file_60);
rows=record.manifest(record.manifest.Scene==scene & record.manifest.Role=="search",:);
parameters=sarflow_statistics("parameter_struct",candidate);
pair=make_range_sft_pair(parameters);
[h,l]=resolve_pair_grids(pair,cfg.sequence,S60,cfg.nyquist_margin);
ch=build_2dsft_carrier(h,pair.H.threshold,S60);cl=build_2dsft_carrier(l,pair.L.threshold,S60);
protocol=record.signature.protocol;
result=sarflow_statistics("process_scene_parameter",cfg,S60,rows,pair,parameters, ...
    protocol,directory,false,ch,cl,cfg.stats.memory_gb,cfg.stats.in_memory,fullfile(checkpoint_directory,"normalization"));
state.fit=struct("input",result.input_stats,"gt",sarflow_fit_gt(cfg,record,scene), ...
    "audit",result.audit,"search_manifest",rows);
sarflow_atomic_save(path,struct("state",state));fit=state.fit;
% 只删除本候选已提交拟合结果的可再生像素chunk，保留checkpoint和fit。
chunks=dir(fullfile(directory,"joint","chunk_*.mat"));
for k=1:numel(chunks),delete(fullfile(chunks(k).folder,chunks(k).name));end
end
