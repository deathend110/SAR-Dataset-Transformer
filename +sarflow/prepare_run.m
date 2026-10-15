function record = prepare_run(cfg)
%PREPARE_RUN 只检查文件头与网格；固定清单并严格核验运行签名。
if cfg.legacy, error('sarflow:LegacyWorkflow','统一入口不接受legacy配置。'); end
if isempty(regexp(char(cfg.run_id),'^[A-Za-z0-9][A-Za-z0-9_-]*$','once'))
    error('sarflow:RunID','RunID只能使用ASCII字母、数字、下划线及连字符。');
end
pairs = cfg.search.hl_pairs;
if size(pairs,2)~=2 || isempty(pairs) || any(~isfinite(pairs),'all') || ...
        any(pairs(:,1)<=pairs(:,2)) || any(pairs(:,2)<1) || size(unique(pairs,'rows'),1)~=size(pairs,1)
    error('sarflow:Pairs','倍率组必须唯一且满足QH>QL>=1。');
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
if ~isequaln(cfg.sequence,defaults.sequence)||cfg.energy_buffer~=64|| ...
        cfg.generate.stride_frames~=3||cfg.nyquist_margin<=0||cfg.nyquist_margin>=1|| ...
        cfg.low_percentile<0||cfg.high_percentile>100||cfg.low_percentile>=cfg.high_percentile|| ...
        cfg.stats.blocks_per_file<1||mod(cfg.stats.blocks_per_file,1)~=0||cfg.stats.memory_gb<=0
    error('sarflow:Protocol','序列、分位数、统计容量或Nyquist配置无效。');
end
if exist('psnr','file')~=2||exist('ssim','file')~=2
    error('sarflow:Toolbox','需要Image Processing Toolbox的psnr和ssim。');
end
S60=load(cfg.parameter_file_60);
required=["nrn","nan","fc","B","Fs","prf","R0","C","v", ...
    "Tp","Ta","gama","lambda","fnrn","fnan","tnrn","tnan","R_total","A_num"];
if ~all(isfield(S60,required))
    error('sarflow:ImagingFields','FS60参数文件缺少成像必需字段。');
end
protocol=sarflow.statistics("build_protocol",cfg,S60,cfg.stats.blocks_per_file, ...
    cfg.low_percentile,cfg.high_percentile,cfg.sequence.roi_size,cfg.energy_buffer);
% 枚举全部来源信息供恢复核验；这里只读取MAT变量头，不加载回波。
inventory=sarflow.statistics("build_scene_manifest",cfg,1);
if numel(unique(inventory.SceneKey))~=numel(cfg.dataset_names)
    error('sarflow:SceneKeyCollision','场景名称映射到重复的输出键。');
end
if S60.nrn~=cfg.sequence.signal_height || S60.nan~=cfg.sequence.signal_width
    error('sarflow:ImagingSize','FS60成像尺寸与生产协议不一致。');
end
for j=1:height(inventory)
    info=whos('-file',inventory.FilePath(j));
    info=info(strcmp(string({info.name}),inventory.EchoVariable(j)));
    if numel(info)~=1 || ~ismember(string(info.class),["double","single"]) || ...
            ~info.complex || info.size(1)<1+3*(cfg.sequence.signal_height-1)
        error('sarflow:EchoSchema','回波必须为足够距离行数的复数single/double矩阵：%s',inventory.FilePath(j));
    end
end
if any(inventory.RawWidth<cfg.sequence.block_width+cfg.stats.blocks_per_file-1)
    error('sarflow:ShortSource','存在无法完成正式统计的轨迹。');
end
if ~isstring(cfg.search.exclude_files)||~isvector(cfg.search.exclude_files)&&~isempty(cfg.search.exclude_files)|| ...
        ~all(ismember(cfg.search.exclude_files,inventory.FilePath))
    error('sarflow:ExcludedFiles','exclude_files必须是清单中轨迹的完整路径string向量。');
end
config=rmfield(cfg,{'stage','provenance'});
config.evaluate=rmfield(config.evaluate,{'workers','chunk_size'});
signature=struct("config",config,"inventory",inventory,"S60",S60,"protocol",protocol);
coarse=table();
for k=1:size(pairs,1)
    rows=sarflow.candidate_grid(cfg,S60,pairs(k,1),pairs(k,2));
    if isempty(coarse),coarse=rows;else,coarse=[coarse;rows];end %#ok<AGROW>
end
if numel(unique(coarse.ParameterKey))~=height(coarse)
    error('sarflow:CandidateKeyCollision','不同候选映射到重复的ASCII参数键。');
end
p=sarflow.paths(cfg); path=fullfile(p.root,"run_record.mat");
if isfile(path)
    old=load(path,'record');
    if ~isfield(old,'record')||~isequaln(old.record.signature,signature)
        error('sarflow:RunMismatch','配置或源文件已改变，请使用新的RunID。');
    end
    record=old.record; % 原清单是唯一恢复依据，不重新抽样。
else
    manifest=make_manifest(cfg,inventory);
    record=struct("signature",signature,"manifest",manifest, ...
        "ranking","scene_equal: MeanSSIM,LRegionSSIM,WorstSSIM,MeanPSNR,ParameterKey", ...
        "confirmation_role","parameter_confirmation_only_not_model_test_split");
    sarflow.atomic_save(path,struct("record",record));
    writetable(manifest,fullfile(p.root,"manifest.csv"));
end
sarflow.atomic_save(fullfile(p.root,"preflight.mat"),struct("candidates",coarse,"record",record));
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
