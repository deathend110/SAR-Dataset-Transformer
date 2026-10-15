function output_root = sarflow_generate_impl(cfg, PARAMETERS)
%RUN_RANGE_2DSFT_GENERATE 可调用的数据生产入口，保留旧输出与恢复校验。
setup_range_2dsft_paths(cfg);
sarflow_validate_roots(cfg);
paths = sarflow_paths(cfg);
REPO_ROOT = cfg.repo_root;
SCRIPT_PATH = fullfile(REPO_ROOT, "run_range_2dsft_generate");
SCENE_NAMES = cfg.dataset_names;
SEQUENCE = cfg.sequence;
NYQUIST_MARGIN = cfg.nyquist_margin;
ENERGY_BUFFER = cfg.energy_buffer;
SEQUENCE_STRIDE_FRAMES = cfg.generate.stride_frames;
MAX_GT_CACHE_FRAMES = cfg.generate.gt_cache_frames;
ENABLE_RANGE_FFT_CACHE = false;
DATA_ROOT = cfg.data_root;
PARAMETER_FILE = cfg.parameter_file_60;
STATS_ROOT = paths.stats;
OUTPUT_PARENT = paths.dataset;
%% ========================== 配置与统计预检 ===============================
range_fft_cache_enabled = evaluate_range_fft_cache_flag( ...
    ENABLE_RANGE_FFT_CACHE);
validate_public_dependencies(REPO_ROOT);
if sarflow_is_fixed(cfg)~=isfield(PARAMETERS,'Q')
    error('rangeSFTDataset:SamplingMode','生产参数与当前采样模式不一致。');
end
validate_configuration(PARAMETERS, SEQUENCE, ...
    SEQUENCE_STRIDE_FRAMES, ENERGY_BUFFER);

S60 = load(PARAMETER_FILE);
pair = make_range_sft_pair(PARAMETERS);
[grid_h, grid_l] = resolve_pair_grids( ...
    pair, SEQUENCE, S60, NYQUIST_MARGIN);
[carrier_h,carrier_l]=sarflow_build_carriers(pair,grid_h,grid_l,S60);

normalization = load_all_scene_normalization( ...
    STATS_ROOT, SCENE_NAMES, PARAMETERS, SEQUENCE, ...
    ENERGY_BUFFER, S60, grid_h, grid_l);
if ~strcmpi(string(normalization(1).Protocol.parameter_file_60), string(PARAMETER_FILE))
    error('rangeSFTDataset:StatsParameterFile', '统计与生产使用的参数文件不同。');
end
parameter_key = string(normalization(1).ParameterKey);
if any(string({normalization.ParameterKey}) ~= parameter_key)
    error('rangeSFTDataset:ParameterKeyMismatch', ...
        '所有场景必须匹配同一个完整参数键。');
end

OUTPUT_ROOT = fullfile(OUTPUT_PARENT, parameter_key);
LQ_ROOT = fullfile(OUTPUT_ROOT, "LQ");
GT_ROOT = fullfile(OUTPUT_ROOT, "GT");
metadata_signature = build_metadata_signature( ...
    SCRIPT_PATH, DATA_ROOT, STATS_ROOT, OUTPUT_ROOT, SCENE_NAMES, ...
    PARAMETERS, parameter_key, SEQUENCE, SEQUENCE_STRIDE_FRAMES, ...
    ENERGY_BUFFER, NYQUIST_MARGIN, grid_h, grid_l, normalization);
metadata_signature.workflow = cfg.provenance;
metadata_signature.normalization_snapshot = sarflow_normalization_snapshot(metadata_signature);
prepare_output_root(OUTPUT_ROOT, LQ_ROOT, GT_ROOT, metadata_signature);

%% =========================== 正式数据集生成 ==============================

generated_count = 0;
skipped_count = 0;

fprintf('Range+2D-SFT数据集参数：%s\n', parameter_key);
fprintf('输出目录：%s\n', OUTPUT_ROOT);
for scene_idx = 1:numel(SCENE_NAMES)
    scene = SCENE_NAMES(scene_idx);
    scene_directory = fullfile(DATA_ROOT, scene);
    files = sarflow_statistics("sort_echo_files", dir(fullfile(scene_directory, "rstart*.mat")));
    if isempty(files)
        error('rangeSFTDataset:EchoFilesMissing', ...
            '场景%s中没有rstart*.mat。', scene);
    end
    scene_key = sarflow_statistics("make_scene_key", scene);
    stats = normalization(scene_idx);

    fprintf('\n[%d/%d] 场景%s，共%d条轨迹。\n', ...
        scene_idx, numel(SCENE_NAMES), scene, numel(files));
    for file_idx = 1:numel(files)
        file = files(file_idx);
        file_path = string(fullfile(file.folder, file.name));
        [raw_data, rstart_id] = load_echo_file(file_path, file.name, S60);
        starts = build_sequence_starts( ...
            size(raw_data, 2), SEQUENCE.block_width, ...
            SEQUENCE_STRIDE_FRAMES * SEQUENCE.step);

        fprintf('  [%d/%d] %s：%d条序列。\n', ...
            file_idx, numel(files), file.name, numel(starts));
        gt_cache = init_gt_cache(MAX_GT_CACHE_FRAMES);
        range_fft_cache = init_range_fft_cache();
        range_fft_totals = init_range_fft_totals();
        for start_idx = 1:numel(starts)
            c_start = starts(start_idx);
            sequence_name = make_sequence_name( ...
                scene_key, rstart_id, c_start);
            state = sarflow_sequence_output(paths,parameter_key,sequence_name);
            if state == "complete"
                skipped_count = skipped_count + 1;
                continue;
            end

            % 只抽取当前连续块需要的距离行，避免额外保存整幅60MHz副本。
            row_indices = 1:3:(1 + 3 * (SEQUENCE.signal_height - 1));
            column_indices = c_start:c_start + SEQUENCE.block_width - 1;
            signal60 = raw_data(row_indices, column_indices);
            validate_echo_block(signal60, SEQUENCE, file_path, c_start);

            if range_fft_cache_enabled
                [signal_up_h, range_fft_cache.H, stats_h] = ...
                    update_range_fft_cache( ...
                    signal60, c_start, grid_h.upsampled_size(1), ...
                    range_fft_cache.H);
                [signal_up_l, range_fft_cache.L, stats_l] = ...
                    update_range_fft_cache( ...
                    signal60, c_start, grid_l.upsampled_size(1), ...
                    range_fft_cache.L);
                range_fft_totals = add_range_fft_totals( ...
                    range_fft_totals, stats_h, stats_l);
            else
                signal_up_h = [];
                signal_up_l = [];
            end

            [lq_sequence, gt_sequence, gt_cache] = generate_sequence( ...
                signal60, S60, pair, SEQUENCE, ...
                ENERGY_BUFFER, stats.Input, stats.GT, ...
                carrier_h, carrier_l, c_start, gt_cache, ...
                signal_up_h, signal_up_l);
            sarflow_commit_sequence(paths,parameter_key,sequence_name, ...
                lq_sequence,gt_sequence,metadata_signature);
            generated_count = generated_count + 1;
            clear signal_up_h signal_up_l
        end
        print_gt_cache_summary(gt_cache, file.name);
        print_range_fft_summary(range_fft_totals, file.name, ...
            range_fft_cache_enabled);
        clear raw_data;
    end
end

fprintf('\n数据集生成完成：新增%d条，跳过%d条完整序列。\n', ...
    generated_count, skipped_count);
fprintf('输出目录：%s\n', OUTPUT_ROOT);

%% ============================== 本地函数 =================================
output_root = OUTPUT_ROOT;
end

function validate_public_dependencies(repo_root)
% 检查实际普通源码目录和当前MATLAB路径，避免误用其他工程同名函数。
groups=struct("sarproc",["Range_Compress","RCMC","SAR_Imaging","estimate_rc_alignment","align_and_mix_rc","focus_base_rc","generate_gt_image"], ...
    "utils",["minmaxnormalize_image","crop_center"], ...
    "sampling",["upsample_range_fft","crop_range_spectrum","resolve_range_grid"], ...
    "sft",["quantize_1bit","build_2dsft_carrier","build_2dsft_threshold","resolve_azimuth_bandwidth","resolve_pair_grids","make_range_sft_pair","generate_range_2dsft_rc"]);
for folder=string(fieldnames(groups)).'
    for name=groups.(folder)
        expected=fullfile(repo_root,"src",folder,name+".m");
        if ~isfile(expected)||~strcmpi(string(which(name)),expected)
            error('rangeSFTDataset:DependencyMissing','公共函数路径错误：%s',expected);
        end
    end
end
end

function validate_configuration(parameters, sequence, stride_frames, buffer)
%VALIDATE_CONFIGURATION 检查固定九帧协议和生产参数的基本合法性。
fixed=isfield(parameters,'Q');
parameter_names=["Method",sarflow_parameter_columns(fixed)];
if ~all(isfield(parameters, parameter_names)) || ...
        string(parameters.Method) ~= "Range_2D_SFT"
    error('rangeSFTDataset:ParameterSchema', ...
        '参数必须完整描述一组Range_2D_SFT配置。');
end
values=zeros(1,numel(parameter_names)-1);
for k=2:numel(parameter_names),values(k-1)=parameters.(parameter_names(k));end
if fixed,invalid_q=parameters.Q<1;
else,invalid_q=parameters.QHigh<=parameters.QLow||parameters.QLow<1;end
if any(~isfinite(values))||invalid_q||parameters.FrOverBr<0||parameters.FaOverBa<0
    error('rangeSFTDataset:ParameterValues','倍率必须>=1，混合模式QH>QL，SFT频率非负且参数有限。');
end
expected_sequence = struct( ...
    "n_frames", 9, "step", 128, ...
    "signal_height", 1200, "signal_width", 1200, ...
    "patch_size", 512, "roi_size", 600, ...
    "valid_margin", 344, "logic_length", 1536, ...
    "block_width", 2224);
if ~isequaln(sequence, expected_sequence)
    error('rangeSFTDataset:SequenceProtocol', ...
        '数据生成必须使用固定的1200×2224九帧几何协议。');
end
if stride_frames ~= 3 || (~fixed && buffer ~= 64)
    error('rangeSFTDataset:FixedProductionProtocol', ...
        '序列间距必须为3帧，RC边界buffer必须为64列。');
end
end

function normalization = load_all_scene_normalization( ...
        stats_root, scenes, parameters, sequence, buffer, ...
        S60, grid_h, grid_l)
%LOAD_ALL_SCENE_NORMALIZATION 预先加载并验证七场景生产分位数。
if ~isfolder(stats_root)
    error('rangeSFTDataset:StatsRootMissing', ...
        ['找不到场景分位数目录：%s。请先运行' ...
        'run_range_2dsft_stats。'], stats_root);
end
empty = struct("Scene", "", "SceneKey", "", "StatsFile", "", ...
    "ParameterKey", "", "Input", struct(), "GT", struct(), ...
    "Protocol", struct(), "SceneUpdatedAt", "", "EntryUpdatedAt", "");
normalization = repmat(empty, numel(scenes), 1);
for idx = 1:numel(scenes)
    normalization(idx) = load_scene_normalization( ...
        stats_root, scenes(idx), parameters, sequence, buffer, ...
        S60, grid_h, grid_l);
end
reference_protocol = normalization(1).Protocol;
for idx = 2:numel(normalization)
    if ~isequaln(normalization(idx).Protocol, reference_protocol)
        error('rangeSFTDataset:StatsProtocolMismatch', ...
            '场景%s的分位数协议与其他场景不一致。', ...
            normalization(idx).Scene);
    end
end
end

function output = load_scene_normalization( ...
        stats_root, scene, parameters, sequence, buffer, ...
        S60, grid_h, grid_l)
%LOAD_SCENE_NORMALIZATION 按场景和完整参数键读取JointHL及GT统计。
scene_key = sarflow_statistics("make_scene_key", scene);
file_path = fullfile(stats_root, scene_key + ".mat");
if ~isfile(file_path)
    error('rangeSFTDataset:SceneStatsMissing', ...
        '缺少场景%s的分位数文件：%s。', scene, file_path);
end
loaded = load(file_path, 'scene_stats');
if ~isfield(loaded, 'scene_stats')
    error('rangeSFTDataset:SceneStatsSchema', ...
        '分位数文件缺少scene_stats：%s。', file_path);
end
stats = loaded.scene_stats;
required = ["schema_version", "scene_name", "scene_key", ...
    "protocol", "gt", "entries", "updated_at"];
if ~all(isfield(stats, required)) || ...
        string(stats.schema_version) ~= "range_2dsft_scene_percentiles_v2" || ...
        ~strcmpi(string(stats.scene_name), scene) || ...
        string(stats.scene_key) ~= scene_key
    error('rangeSFTDataset:SceneStatsIdentity', ...
        '场景分位数身份或schema不匹配：%s。', file_path);
end
verify_stats_protocol(stats.protocol, sequence, buffer, S60, file_path,isfield(parameters,'Q'));

parameter_key = sarflow_statistics("make_parameter_key", parameters, stats.protocol);
if isempty(stats.entries)
    error('rangeSFTDataset:StatsEntriesEmpty', ...
        '场景%s没有任何Range+2D-SFT参数统计。', scene);
end
entry_keys = string({stats.entries.parameter_key});
match = find(entry_keys == parameter_key);
if numel(match) ~= 1
    error('rangeSFTDataset:ParameterStatsMatch', ...
        '场景%s中参数键%s必须且只能匹配一个统计条目。', ...
        scene, parameter_key);
end
entry = stats.entries(match);
if ~isequaln(entry.parameters, parameters)
    error('rangeSFTDataset:ParameterStatsMismatch', ...
        '场景%s的参数键与条目内实际参数不一致。', scene);
end
if isfield(parameters,'Q')
    if ~isfield(entry,'effective_sampling')||~isfield(entry.effective_sampling,'Single')
        error('rangeSFTDataset:SamplingStatsMissing','固定Q统计缺少Single有效采样网格。');
    end
    verify_effective_grid(entry.effective_sampling.Single,grid_h,"Single",scene);
    validate_normalization_stats(entry.input_stats,"FixedQ",stats.protocol);
else
    if ~isfield(entry,'effective_sampling')||~all(isfield(entry.effective_sampling,["H","L"]))
        error('rangeSFTDataset:SamplingStatsMissing','混合统计缺少H/L有效采样网格。');
    end
    verify_effective_grid(entry.effective_sampling.H,grid_h,"H",scene);
    verify_effective_grid(entry.effective_sampling.L,grid_l,"L",scene);
    validate_normalization_stats(entry.input_stats,"JointHL",stats.protocol);
end
validate_normalization_stats(stats.gt, "GT", stats.protocol);

output = struct( ...
    "Scene", string(scene), ...
    "SceneKey", scene_key, ...
    "StatsFile", string(file_path), ...
    "ParameterKey", parameter_key, ...
    "Input", entry.input_stats, ...
    "GT", stats.gt, ...
    "Protocol", stats.protocol, ...
    "SceneUpdatedAt", string(stats.updated_at), ...
    "EntryUpdatedAt", string(entry.updated_at));
end

function verify_stats_protocol(protocol, sequence, buffer, S60, file_path, fixed)
%VERIFY_STATS_PROTOCOL 确认统计值来自当前采样模式、生产成像及归一化协议。
required = ["method", "working_echo", "parameter_file_60", ...
    "low_percentile", "high_percentile", "percentile_method", ...
    "roi_size", "joint_pool", "mixed_pixels_in_pool", "sequence", "imaging"];
if fixed
    valid_pool=isfield(protocol,'sampling_mode')&&protocol.sampling_mode=="fixed_q"&& ...
        isfield(protocol,'joint_pool')&&protocol.joint_pool=="single_branch_all_9_frames";
else
    valid_pool=isfield(protocol,'energy_buffer')&&protocol.energy_buffer==buffer&& ...
        isfield(protocol,'joint_pool')&&protocol.joint_pool=="equal_pixels_H_aligned_and_L_all_9_frames";
end
if ~all(isfield(protocol, required)) || ...
        string(protocol.method) ~= "Range_2D_SFT" || ...
        string(protocol.working_echo) ~= "60MHz_from_180MHz_stride3" || ...
        string(protocol.percentile_method) ~= "midpoint_exact_tall" || ...
        protocol.roi_size ~= sequence.roi_size || ...
        ~valid_pool || ...
        logical(protocol.mixed_pixels_in_pool) || ...
        ~isequaln(protocol.sequence, sequence)
    error('rangeSFTDataset:StatsProtocol', ...
        '场景分位数不是当前采样模式的生产协议：%s。', file_path);
end
if protocol.low_percentile < 0 || protocol.high_percentile > 100 || ...
        protocol.low_percentile >= protocol.high_percentile
    error('rangeSFTDataset:StatsPercentiles', ...
        '场景分位数协议范围无效：%s。', file_path);
end
if ~isequaln(protocol.imaging, sarflow_statistics("imaging_parameters",S60))
    error('rangeSFTDataset:StatsImaging', ...
        '统计协议中的成像参数与当前FS60_params.mat不一致：%s。', file_path);
end
end

function validate_normalization_stats(stats, modality, protocol)
%VALIDATE_NORMALIZATION_STATS 检查归一化上下限和统计身份。
required = ["Modality", "VMin", "VMax", "ImageCount", ...
    "PixelCount", "LowPercentile", "HighPercentile", "Method"];
if ~all(isfield(stats, required)) || ...
        string(stats.Modality) ~= string(modality) || ...
        ~isfinite(stats.VMin) || ~isfinite(stats.VMax) || ...
        stats.VMax <= stats.VMin || stats.ImageCount <= 0 || ...
        stats.PixelCount <= 0 || ...
        stats.LowPercentile ~= protocol.low_percentile || ...
        stats.HighPercentile ~= protocol.high_percentile || ...
        string(stats.Method) ~= "midpoint_exact_tall"
    error('rangeSFTDataset:NormalizationStats', ...
        '%s归一化统计无效或与场景协议不一致。', modality);
end
end

function verify_effective_grid(actual, expected, label, scene)
%VERIFY_EFFECTIVE_GRID 防止分位数与数据生成使用不同的整数采样网格。
names = ["q_range", "q_azimuth", "q_range_eff", ...
    "q_azimuth_eff", "q_total_eff", "input_size", ...
    "upsampled_size", "Fs_up", "PRF_up"];
if ~all(isfield(actual, names))
    error('rangeSFTDataset:EffectiveGridSchema', ...
        '场景%s的%s网格字段不完整。', scene, label);
end
for name = names
    if ~isequaln(actual.(name), expected.(name))
        error('rangeSFTDataset:EffectiveGridMismatch', ...
            '场景%s的%s有效采样字段%s与当前参数不一致。', ...
            scene, label, name);
    end
end
end

function signature = build_metadata_signature( ...
        script_path, data_root, stats_root, output_root, scenes, ...
        parameters, parameter_key, sequence, stride_frames, buffer, ...
        nyquist_margin, grid_h, grid_l, normalization)
%BUILD_METADATA_SIGNATURE 记录会改变数据集语义的全部生产配置。
sources = repmat(struct("Scene", "", "StatsFile", "", ...
    "SceneUpdatedAt", "", "EntryUpdatedAt", ""), ...
    numel(normalization), 1);
for idx = 1:numel(normalization)
    sources(idx) = struct( ...
        "Scene", normalization(idx).Scene, ...
        "StatsFile", normalization(idx).StatsFile, ...
        "SceneUpdatedAt", normalization(idx).SceneUpdatedAt, ...
        "EntryUpdatedAt", normalization(idx).EntryUpdatedAt);
end
signature = struct( ...
    "schema_version", "range_2dsft_png_dataset_v1", ...
    "script", string(script_path), ...
    "data_root", string(data_root), ...
    "stats_root", string(stats_root), ...
    "output_root", string(output_root), ...
    "scene_names", string(scenes), ...
    "parameter_key", string(parameter_key), ...
    "parameters", parameters, ...
    "sequence", sequence, ...
    "sequence_stride_frames", stride_frames, ...
    "sequence_stride_columns", stride_frames * sequence.step, ...
    "sequence_overlap_frames", sequence.n_frames - stride_frames, ...
    "energy_buffer", buffer, ...
    "nyquist_margin", nyquist_margin, ...
    "effective_sampling", struct("H", grid_h, "L", grid_l), ...
    "normalization_protocol", normalization(1).Protocol, ...
    "normalization_sources", sources, ...
    "image_format", "uint8_png", ...
    "dataset_split", "none");
if isfield(parameters,'Q')
    signature=rmfield(signature,'energy_buffer');
    signature.sampling_mode="fixed_q";
    signature.effective_sampling=struct("Single",grid_h);
end
end

function prepare_output_root(output_root, lq_root, gt_root, signature)
%PREPARE_OUTPUT_ROOT 创建输出目录并拒绝混用不同生产协议。
metadata_path = fullfile(output_root, "dataset_metadata.mat");
if isfolder(output_root)
    has_lq_content = folder_has_entries(lq_root);
    has_gt_content = folder_has_entries(gt_root);
    if isfile(metadata_path)
        loaded = load(metadata_path, 'dataset_metadata');
        if ~isfield(loaded, 'dataset_metadata') || ...
                ~isfield(loaded.dataset_metadata, 'signature') || ...
                ~sarflow_dataset_compatible(loaded.dataset_metadata.signature, signature)
            error('rangeSFTDataset:MetadataMismatch', ...
                '已有输出目录的metadata与当前生产协议不一致：%s。', ...
                output_root);
        end
        % 仅迁移来源路径或工作流记录时更新metadata；已有PNG保持不动。
        if ~isequaln(loaded.dataset_metadata.signature, signature)
            dataset_metadata = loaded.dataset_metadata;
            dataset_metadata.signature = signature;
            atomic_save_metadata(metadata_path, dataset_metadata);
        end
    elseif has_lq_content || has_gt_content
        error('rangeSFTDataset:MetadataMissing', ...
            '已有输出图像但缺少dataset_metadata.mat：%s。', output_root);
    end
end
ensure_directory(output_root);
ensure_directory(lq_root);
ensure_directory(gt_root);
if ~isfile(metadata_path)
    dataset_metadata = struct( ...
        "created_at", string(datetime('now', ...
        'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSSXXX')), ...
        "signature", signature);
    atomic_save_metadata(metadata_path, dataset_metadata);
end
end

function yes = folder_has_entries(path)
%FOLDER_HAS_ENTRIES 判断目录中是否已有除点目录外的内容。
if ~isfolder(path)
    yes = false;
    return;
end
entries = dir(path);
names = string({entries.name});
yes = any(names ~= "." & names ~= "..");
end

function [raw_data, rstart_id] = load_echo_file(file_path, file_name, S60)
%LOAD_ECHO_FILE 读取单条180MHz复回波轨迹并解析稳定轨迹编号。
variables = whos('-file', file_path);
if isempty(variables) || numel(variables(1).size) ~= 2
    error('rangeSFTDataset:EchoSchema', ...
        '回波文件首个变量必须是二维矩阵：%s。', file_path);
end
variable_name = variables(1).name;
loaded = load(file_path, variable_name);
raw_data = loaded.(variable_name);
required_rows = 1 + 3 * (S60.nrn - 1);
if ~isnumeric(raw_data) || isreal(raw_data) || ~ismatrix(raw_data) || ...
        size(raw_data, 1) < required_rows
    error('rangeSFTDataset:EchoData', ...
        '回波必须是距离行数充足的二维复数矩阵：%s。', file_path);
end
token = regexp(file_name, '^rstart\s*([0-9]+)\.mat$', ...
    'tokens', 'once', 'ignorecase');
if isempty(token)
    error('rangeSFTDataset:RstartName', ...
        '轨迹文件名必须符合rstart <数字>.mat：%s。', file_name);
end
rstart_id = str2double(token{1});
if ~isfinite(rstart_id) || rstart_id < 0 || rstart_id ~= round(rstart_id)
    error('rangeSFTDataset:RstartID', ...
        '无法解析合法的rstart编号：%s。', file_name);
end
end

function starts = build_sequence_starts(raw_width, block_width, stride)
%BUILD_SEQUENCE_STARTS 构造固定步长起点，并保证轨迹尾部恰好覆盖一次。
max_start = raw_width - block_width + 1;
if max_start < 1
    error('rangeSFTDataset:EchoTooShort', ...
        '轨迹宽度%d不足以生成宽度%d的九帧序列。', ...
        raw_width, block_width);
end
starts = 1:stride:max_start;
if starts(end) ~= max_start
    starts(end + 1) = max_start;
end
if numel(starts) ~= numel(unique(starts)) || ...
        starts(1) ~= 1 || starts(end) ~= max_start
    error('rangeSFTDataset:SequenceStarts', ...
        '序列起点必须唯一并完整覆盖轨迹首尾。');
end
end

function validate_echo_block(signal, sequence, file_path, c_start)
%VALIDATE_ECHO_BLOCK 检查降至60MHz后的连续块尺寸和复数属性。
if ~isnumeric(signal) || isreal(signal) || ...
        ~isequal(size(signal), ...
        [sequence.signal_height, sequence.block_width]) || ...
        any(~isfinite(signal), 'all')
    error('rangeSFTDataset:EchoBlock', ...
        '轨迹%s从第%d列抽取的60MHz复回波块无效。', ...
        file_path, c_start);
end
end

function [lq_sequence, gt_sequence, gt_cache] = generate_sequence( ...
        signal, S60, pair, sequence, buffer, input_stats, gt_stats, ...
        carrier_h, carrier_l, c_start, gt_cache, ...
        precomputed_signal_up_h, precomputed_signal_up_l)
%GENERATE_SEQUENCE 由一个连续回波块生成配对的九帧LQ和GT。
[RC_mix, ~] = sarflow_sequence_rc( ...
    signal, S60, pair, sequence, buffer, carrier_h, carrier_l, ...
    precomputed_signal_up_h, precomputed_signal_up_l);

lq_sequence = zeros(sequence.patch_size, sequence.patch_size, ...
    sequence.n_frames, 'uint8');
gt_sequence = zeros(size(lq_sequence), 'uint8');
for frame_idx = 1:sequence.n_frames
    columns = sarflow_frame_columns(sequence, frame_idx);
    lq_roi = focus_base_rc(RC_mix(:, columns), S60, sequence.roi_size);
    global_frame_start = c_start + (frame_idx - 1) * sequence.step;
    [gt_frame, gt_cache] = get_gt_frame_cached( ...
        signal(:, columns), S60, sequence, gt_stats, ...
        global_frame_start, gt_cache);

    % 必须先在600×600 ROI上使用生产分位数归一化，再中心裁剪到512。
    lq_sequence(:, :, frame_idx) = sarflow_normalize_frame( ...
        lq_roi, input_stats, sequence.patch_size);
    gt_sequence(:, :, frame_idx) = gt_frame;
end
end

function cache = init_gt_cache(max_frames)
%INIT_GT_CACHE 初始化单个rstart轨迹使用的有界GT帧缓存。
if ~isscalar(max_frames) || max_frames < 1 || max_frames ~= fix(max_frames)
    error('rangeSFTDataset:GTCacheSize', ...
        'GT缓存容量必须是正整数。');
end
cache = struct( ...
    "max_frames", double(max_frames), ...
    "keys", nan(1, max_frames), ...
    "frames", {cell(1, max_frames)}, ...
    "count", 0, ...
    "next_slot", 1, ...
    "hits", 0, ...
    "misses", 0);
end

function [gt_frame, cache] = get_gt_frame_cached( ...
        signal_frame, S60, sequence, gt_stats, global_frame_start, cache)
%GET_GT_FRAME_CACHED 按轨迹内全局帧起点复用最终uint8 GT帧。
if ~isscalar(global_frame_start) || ~isfinite(global_frame_start) || ...
        global_frame_start < 1 || global_frame_start ~= fix(global_frame_start)
    error('rangeSFTDataset:GTCacheKey', ...
        'GT缓存键必须是正整数的轨迹全局帧起点。');
end
slot = find(cache.keys(1:cache.count) == global_frame_start, 1);
if ~isempty(slot)
    gt_frame = cache.frames{slot};
    cache.hits = cache.hits + 1;
    return;
end

gt_roi = generate_gt_image(signal_frame, S60, sequence.roi_size);
gt_frame = sarflow_normalize_frame(gt_roi, gt_stats, sequence.patch_size);

if cache.count < cache.max_frames
    cache.count = cache.count + 1;
    slot = cache.count;
else
    slot = cache.next_slot;
    cache.next_slot = mod(cache.next_slot, cache.max_frames) + 1;
end
cache.keys(slot) = global_frame_start;
cache.frames{slot} = gt_frame;
cache.misses = cache.misses + 1;
end

function print_gt_cache_summary(cache, file_name)
%PRINT_GT_CACHE_SUMMARY 每条rstart轨迹结束时汇总GT缓存命中情况。
total = cache.hits + cache.misses;
if total == 0
    hit_rate = 0;
else
    hit_rate = cache.hits / total;
end
fprintf('    GT cache %s：hits=%d, misses=%d, hit rate=%.1f%%。\n', ...
    file_name, cache.hits, cache.misses, 100 * hit_rate);
end

function enabled = evaluate_range_fft_cache_flag(value)
%EVALUATE_RANGE_FFT_CACHE_FLAG 将配置开关转换为单一逻辑标量。
if ~isscalar(value) || ~islogical(value)
    error('rangeSFTDataset:RangeFFTCacheFlag', ...
        'ENABLE_RANGE_FFT_CACHE必须是逻辑标量。');
end
enabled = value;
end

function cache = init_range_fft_cache()
%INIT_RANGE_FFT_CACHE 初始化单个rstart文件的H/L距离FFT缓存。
empty_branch = struct( ...
    "valid", false, "c_start", nan, "target_rows", nan, ...
    "input_width", nan, "signal_up", []);
cache = struct("H", empty_branch, "L", empty_branch);
end

function totals = init_range_fft_totals()
%INIT_RANGE_FFT_TOTALS 初始化距离FFT缓存的列级审计计数。
totals = struct( ...
    "full_fft_columns", 0, "reused_columns", 0, ...
    "newly_fft_columns", 0);
end

function [signal_up, cache, stats] = update_range_fft_cache( ...
        signal, c_start, target_rows, cache)
%UPDATE_RANGE_FFT_CACHE 按真实轨迹区间拼接当前距离FFT结果。
% 仅复用signal_up列；阈值、量化、距离压缩及后续流程每条序列重新执行。
if ~isscalar(c_start) || ~isfinite(c_start) || ...
        c_start < 1 || c_start ~= fix(c_start)
    error('rangeSFTDataset:RangeFFTCacheKey', ...
        '距离FFT缓存键必须是正整数的轨迹全局列起点。');
end
if ~isscalar(target_rows) || ~isfinite(target_rows) || ...
        target_rows < size(signal, 1) || target_rows ~= fix(target_rows)
    error('rangeSFTDataset:RangeFFTCacheRows', ...
        '距离FFT缓存目标行数必须是不小于输入行数的整数。');
end
input_width = size(signal, 2);
stats = struct("full_fft_columns", 0, "reused_columns", 0, ...
    "newly_fft_columns", 0);

if ~cache.valid || cache.target_rows ~= target_rows || ...
        cache.input_width ~= input_width || isempty(cache.signal_up)
    signal_up = upsample_range_fft(signal, target_rows);
    stats.full_fft_columns = input_width;
    stats.newly_fft_columns = input_width;
    cache.valid = true;
    cache.c_start = c_start;
    cache.target_rows = target_rows;
    cache.input_width = input_width;
    cache.signal_up = signal_up;
    return;
end

previous_start = cache.c_start;
previous_end = previous_start + cache.input_width - 1;
current_end = c_start + input_width - 1;
overlap_start = max(previous_start, c_start);
overlap_end = min(previous_end, current_end);
overlap = overlap_end - overlap_start + 1;
if overlap <= 0
    signal_up = upsample_range_fft(signal, target_rows);
    stats.full_fft_columns = input_width;
    stats.newly_fft_columns = input_width;
else
    signal_up = zeros(target_rows, input_width, 'like', cache.signal_up);
    current_overlap = (overlap_start - c_start + 1): ...
        (overlap_end - c_start + 1);
    previous_overlap = (overlap_start - previous_start + 1): ...
        (overlap_end - previous_start + 1);
    signal_up(:, current_overlap) = cache.signal_up(:, previous_overlap);
    new_columns = true(1, input_width);
    new_columns(current_overlap) = false;
    if any(new_columns)
        signal_up(:, new_columns) = upsample_range_fft( ...
            signal(:, new_columns), target_rows);
    end
    stats.reused_columns = overlap;
    stats.newly_fft_columns = input_width - overlap;
end

cache.valid = true;
cache.c_start = c_start;
cache.target_rows = target_rows;
cache.input_width = input_width;
cache.signal_up = signal_up;
end

function totals = add_range_fft_totals(totals, stats_h, stats_l)
%ADD_RANGE_FFT_TOTALS 汇总H/L两套缓存的列级统计。
totals.full_fft_columns = totals.full_fft_columns + ...
    stats_h.full_fft_columns + stats_l.full_fft_columns;
totals.reused_columns = totals.reused_columns + ...
    stats_h.reused_columns + stats_l.reused_columns;
totals.newly_fft_columns = totals.newly_fft_columns + ...
    stats_h.newly_fft_columns + stats_l.newly_fft_columns;
end

function print_range_fft_summary(totals, file_name, enabled)
%PRINT_RANGE_FFT_SUMMARY 每条rstart轨迹结束时汇总距离FFT缓存列数。
if ~enabled
    return;
end
total_columns = totals.full_fft_columns + totals.reused_columns;
if total_columns == 0
    reuse_rate = 0;
else
    reuse_rate = totals.reused_columns / total_columns;
end
fprintf(['    Range FFT cache %s：full=%d, reused=%d, ' ...
    'new=%d, reuse rate=%.1f%%。\n'], file_name, ...
    totals.full_fft_columns, totals.reused_columns, ...
    totals.newly_fft_columns, 100 * reuse_rate);
end

function atomic_save_metadata(file_path, dataset_metadata)
%ATOMIC_SAVE_METADATA 使用同目录临时文件原子提交数据集元数据。
directory = string(fileparts(file_path));
temporary = string(tempname(directory)) + ".mat";
cleanup = onCleanup(@() delete_if_exists(temporary));
save(temporary, 'dataset_metadata');
[ok, message] = movefile(temporary, file_path);
if ~ok
    error('rangeSFTDataset:MetadataSave', ...
        '提交数据集metadata失败：%s。', message);
end
clear cleanup;
end

function delete_if_exists(file_path)
%DELETE_IF_EXISTS 删除本次未成功提交的临时metadata文件。
if isfile(file_path)
    delete(file_path);
end
end

function ensure_directory(path)
%ENSURE_DIRECTORY 确保目标目录存在且可访问。
if isfolder(path)
    return;
end
[ok, message] = mkdir(path);
if ~ok
    error('rangeSFTDataset:CreateDirectory', ...
        '无法创建目录%s：%s。', path, message);
end
end

function name = make_sequence_name(scene_key, rstart_id, c_start)
%MAKE_SEQUENCE_NAME 沿用已有数据集的六位轨迹号与九位起点格式。
name=string(sprintf('%s_rstart_%06d_cstart_%09d',scene_key,rstart_id,c_start));
end
