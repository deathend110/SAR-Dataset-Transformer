function record = sarflow_prepare_run(cfg)
%PREPARE_RUN 首次建立来源清单；恢复只核对实际参数并复用原抽样。
fixed=sarflow_is_fixed(cfg);
sarflow_search_cache_budget(cfg);
if fixed
    q=cfg.search.fixed_q_values;
    if ~isnumeric(q)||~isvector(q)||isempty(q)||any(~isfinite(q))||any(q<1)||numel(unique(q))~=numel(q)
        error('sarflow:FixedQ','固定Q必须是唯一、有限且不小于1的数值向量。');
    end
    pairs=[q(:),zeros(numel(q),1)];
else
    pairs=cfg.search.hl_pairs;
    if size(pairs,2)~=2||isempty(pairs)||any(~isfinite(pairs),'all')|| ...
            any(pairs(:,1)<=pairs(:,2))||any(pairs(:,2)<1)||size(unique(pairs,'rows'),1)~=size(pairs,1)
        error('sarflow:Pairs','倍率组必须唯一且满足QH>QL>=1。');
    end
end
for name=["STR_grid","fr_grid","fa_grid","fine_STR_offsets","fine_frequency_offsets"]
    v=cfg.search.(name);
    if ~isnumeric(v)||~isvector(v)||isempty(v)||any(~isfinite(v))
        error('sarflow:Grid','搜索网格必须是有限数值向量：%s',name);
    end
end
if cfg.search.phi0~=0 || cfg.search.search_per_scene<1 || cfg.search.confirm_per_scene<1 || ...
        any(mod([cfg.search.search_per_scene,cfg.search.confirm_per_scene],1)~=0)
    error('sarflow:SearchConfig','初相位固定0，样本量必须为正整数。');
end
if ~isstring(cfg.dataset_names)||~isrow(cfg.dataset_names)
    error('sarflow:SceneShape','dataset_names必须为string行向量。');
end
if numel(unique(cfg.dataset_names))~=numel(cfg.dataset_names)||isempty(cfg.dataset_names)
    error('sarflow:Scenes','场景必须非空且唯一。');
end
% 固定成像协议与正式生产入口一致。
defaults=range_2dsft_config();
sarflow_check_parameters(cfg.sequence,defaults.sequence,"九帧几何");
if (~fixed&&cfg.energy_buffer~=64)|| ...
        cfg.generate.stride_frames~=3||cfg.nyquist_margin<=0||cfg.nyquist_margin>=1|| ...
        cfg.low_percentile<0||cfg.high_percentile>100||cfg.low_percentile>=cfg.high_percentile|| ...
        cfg.stats.blocks_per_file<1||mod(cfg.stats.blocks_per_file,1)~=0||cfg.stats.memory_gb<=0
    error('sarflow:Protocol','序列、分位数、统计容量或Nyquist配置无效。');
end
if exist('psnr','file')~=2||exist('ssim','file')~=2
    error('sarflow:Toolbox','需要Image Processing Toolbox的psnr和ssim。');
end
sarflow_validate_roots(cfg);
S60=load(cfg.parameter_file_60);
required=["nrn","nan","fc","B","Fs","prf","R0","C","v", ...
    "Tp","Ta","gama","lambda","fnrn","fnan","tnrn","tnan","R_total","A_num"];
if ~all(isfield(S60,required))
    error('sarflow:ImagingFields','FS60参数文件缺少成像必需字段。');
end
protocol=sarflow_statistics("build_protocol",cfg,S60,cfg.stats.blocks_per_file, ...
    cfg.low_percentile,cfg.high_percentile,cfg.sequence.roi_size,cfg.energy_buffer);
p=sarflow_paths(cfg);path=fullfile(p.protocol,"run_record.mat");
resuming=isfile(path);
if resuming
    saved=load(path,'record');record=saved.record;
    sarflow_check_parameters(record.signature.config,cfg,"工作流");
    sarflow_check_parameters(record.signature.S60,S60,"成像参数");
    inventory=record.signature.inventory;
    inventory.FilePath=fullfile(cfg.data_root,inventory.Scene,inventory.File);
else
    inventory=sarflow_statistics("build_scene_manifest",cfg,1);
end
if numel(unique(inventory.SceneKey))~=numel(cfg.dataset_names)
    error('sarflow:SceneKeyCollision','场景名称映射到重复的输出键。');
end
if S60.nrn~=cfg.sequence.signal_height || S60.nan~=cfg.sequence.signal_width
    error('sarflow:ImagingSize','FS60成像尺寸与生产协议不一致。');
end
if ~resuming
for j=1:height(inventory)
    info=whos('-file',inventory.FilePath(j));
    info=info(strcmp(string({info.name}),inventory.EchoVariable(j)));
    if numel(info)~=1 || ~ismember(string(info.class),["double","single"]) || ...
            ~info.complex || info.size(1)<1+3*(cfg.sequence.signal_height-1)
        error('sarflow:EchoSchema','回波必须为足够距离行数的复数single/double矩阵：%s',inventory.FilePath(j));
    end
end
end
if any(inventory.RawWidth<cfg.sequence.block_width+cfg.stats.blocks_per_file-1)
    error('sarflow:ShortSource','存在无法完成正式统计的轨迹。');
end
if ~isstring(cfg.search.exclude_files)||~isvector(cfg.search.exclude_files)&&~isempty(cfg.search.exclude_files)
    error('sarflow:ExcludedFiles','exclude_files必须为string向量。');
end
config=rmfield(cfg,{'stage','provenance'});
if isfield(config,'search_runtime'),config=rmfield(config,'search_runtime');end
config.evaluate=rmfield(config.evaluate,{'workers','chunk_size'});
% 保留来源记录格式；只记录本模式使用的倍率参数。
if fixed
    config.search=rmfield(config.search,'hl_pairs');
    config=rmfield(config,'energy_buffer');
else
    config=rmfield(config,'sampling_mode');
    config.search=rmfield(config.search,'fixed_q_values');
end
% 以下信息仅作来源追溯，恢复不比较整个封套。
signature=struct("config",config,"inventory",inventory,"S60",S60,"protocol",protocol);
coarse=table();
for k=1:size(pairs,1)
    rows=sarflow_candidate_grid(cfg,S60,pairs(k,1),pairs(k,2));
    if isempty(coarse),coarse=rows;else,coarse=[coarse;rows];end %#ok<AGROW>
end
if numel(unique(coarse.ParameterKey))~=height(coarse)
    error('sarflow:CandidateKeyCollision','不同候选映射到重复的ASCII参数键。');
end
if resuming
    % 路径是定位信息，数据根目录变更时按场景及文件名重定位，不比较旧路径。
    record.manifest.FilePath=fullfile(cfg.data_root,record.manifest.Scene,record.manifest.File);
else
    manifest=make_manifest(cfg,inventory);
    ranking="scene_equal: MeanSSIM,LRegionSSIM,WorstSSIM,MeanPSNR,ParameterKey";
    if fixed,ranking="scene_equal: MeanSSIM,WorstSSIM,MeanPSNR,ParameterKey";end
    record=struct("signature",signature,"manifest",manifest, ...
        "ranking",ranking, ...
        "confirmation_role","parameter_confirmation_only_not_model_test_split");
    sarflow_atomic_save(path,struct("record",record));
    writetable(manifest,fullfile(p.protocol,"manifest.csv"));
end
sarflow_atomic_save(fullfile(p.protocol,"preflight.mat"),struct("candidates",coarse,"record",record));
fprintf('预检完成：%d条搜索、%d条确认、%d个粗候选。未运行成像。\n', ...
    sum(record.manifest.Role=="search"),sum(record.manifest.Role=="confirm"),height(coarse));
end

function manifest=make_manifest(cfg,inventory)
manifest=table(); n=cfg.search.search_per_scene+cfg.search.confirm_per_scene;
% 默认7条中的第3、5条确认；其他样本预算采用内部等距位置。
if n==7&&cfg.search.confirm_per_scene==2, confirm=[3,5];
else,confirm=round((1:cfg.search.confirm_per_scene)*(n+1)/(cfg.search.confirm_per_scene+1));end
for scene=cfg.dataset_names
    rows=inventory(inventory.Scene==scene & ~ismember(inventory.FilePath,cfg.search.exclude_files),:);
    if height(rows)<n,error('sarflow:InsufficientTrajectories','场景%s至少需要%d条轨迹。',scene,n);end
    positions=ceil(((1:n)-0.5)/n*height(rows));
    chosen=rows(positions,:);
    chosen.Role=repmat("search",n,1);chosen.Role(confirm)="confirm";
    for j=1:n
        max_start=chosen.RawWidth(j)-cfg.sequence.block_width+1;
        chosen.CStart(j)=min(max(round((j-0.5)/n*max_start),1),max_start);
    end
    chosen.SequenceID=(height(manifest)+(1:n)).';
    if isempty(manifest),manifest=chosen;else,manifest=[manifest;chosen];end %#ok<AGROW>
end
end
