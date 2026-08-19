clear; clc; close all;

%% ========================================================================
% Range+2D-SFT 九帧H-L-H数据集生成脚本
%
% 本脚本直接生成用于图像恢复训练的LQ/GT灰度PNG。每条序列包含9帧，
% 相邻帧在连续回波上移动128列；相邻序列起点移动3帧，即384列。
% LQ使用场景级JointHL分位数，GT使用同一场景独立统计的GT分位数。
%
% 运行前必须先完成compute_range_2dsft_scene_percentiles.m的正式统计。
% 脚本不依赖+sarvalid，也不会自动搜索参数或重新估计归一化范围。
%% ========================================================================

%% ============================== 参数区 ==================================
SCENE_NAMES = [ ...
    "SAR_Dataset_Bangkok_1", "SAR_Dataset_city1_histeq", ...
    "SAR_Dataset_city2_histeq", "SAR_Dataset_SAR_figure", ...
    "SAR_Dataset_filed", "SAR_Dataset_port", "SAR_Dataset_suburb"];

% 默认使用V3锁定的qH=4、qL=2生产参数。切换倍率时必须同时修改全部SFT参数。
PARAMETERS = struct( ...
    "Method", "Range_2D_SFT", ...
    "QHigh", 4, ...
    "QLow", 2, ...
    "STRdB", -1, ...
    "FrOverBr", 1.3, ...
    "FaOverBa", 0.5, ...
    "Phi0", 0);

NYQUIST_MARGIN = 0.98; % SFT频率相对共同Nyquist上限保留2%安全余量
ENERGY_BUFFER = 64;    % 两个H/L边界每侧用于功率估计的RC列数
SEQUENCE_STRIDE_FRAMES = 3;

% 该结构必须与场景分位数统计协议中的sequence逐字段一致。
SEQUENCE = struct( ...
    "n_frames", 9, "step", 128, ...
    "signal_height", 1200, "signal_width", 1200, ...
    "patch_size", 512, "roi_size", 600, ...
    "valid_margin", 344, "logic_length", 1536, ...
    "block_width", 2224);

SCRIPT_PATH = string(mfilename('fullpath'));
if strlength(SCRIPT_PATH) == 0
    error('rangeSFTDataset:ScriptPath', '无法解析当前脚本路径。');
end
REPO_ROOT = string(fileparts(SCRIPT_PATH));
DATA_ROOT = "G:\MATLAB-G\SAR Full PSF";
PARAMETER_FILE = fullfile(REPO_ROOT, "FS60_params.mat");
STATS_ROOT = fullfile(REPO_ROOT, "results_range_2dsft_scene_percentiles");
OUTPUT_PARENT = fullfile(REPO_ROOT, "dataset_range_2dsft");

%% ========================== 配置与统计预检 ===============================
addpath(REPO_ROOT);
validate_public_dependencies(REPO_ROOT);
validate_configuration(PARAMETERS, SEQUENCE, ...
    SEQUENCE_STRIDE_FRAMES, ENERGY_BUFFER);

S60 = load(PARAMETER_FILE);
pair = make_range_sft_pair(PARAMETERS);
[grid_h, grid_l] = resolve_pair_grids( ...
    pair, SEQUENCE, S60, NYQUIST_MARGIN);
carrier_h = build_2dsft_carrier(grid_h, pair.H.threshold, S60);
carrier_l = build_2dsft_carrier(grid_l, pair.L.threshold, S60);

normalization = load_all_scene_normalization( ...
    STATS_ROOT, SCENE_NAMES, PARAMETERS, SEQUENCE, ...
    ENERGY_BUFFER, S60, grid_h, grid_l);
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
prepare_output_root(OUTPUT_ROOT, LQ_ROOT, GT_ROOT, metadata_signature);

%% =========================== 正式数据集生成 ==============================
mode_mask = build_hlh_mask(SEQUENCE);
generated_count = 0;
skipped_count = 0;

fprintf('Range+2D-SFT数据集参数：%s\n', parameter_key);
fprintf('输出目录：%s\n', OUTPUT_ROOT);
for scene_idx = 1:numel(SCENE_NAMES)
    scene = SCENE_NAMES(scene_idx);
    scene_directory = fullfile(DATA_ROOT, scene);
    files = sort_echo_files(dir(fullfile(scene_directory, "rstart*.mat")));
    if isempty(files)
        error('rangeSFTDataset:EchoFilesMissing', ...
            '场景%s中没有rstart*.mat。', scene);
    end
    scene_key = make_scene_key(scene);
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
        for start_idx = 1:numel(starts)
            c_start = starts(start_idx);
            sequence_name = make_sequence_name( ...
                scene_key, rstart_id, c_start);
            state = inspect_sequence_output( ...
                LQ_ROOT, GT_ROOT, sequence_name, SEQUENCE.n_frames);
            if state == "complete"
                skipped_count = skipped_count + 1;
                continue;
            end

            % 只抽取当前连续块需要的距离行，避免额外保存整幅60MHz副本。
            row_indices = 1:3:(1 + 3 * (SEQUENCE.signal_height - 1));
            column_indices = c_start:c_start + SEQUENCE.block_width - 1;
            signal60 = raw_data(row_indices, column_indices);
            validate_echo_block(signal60, SEQUENCE, file_path, c_start);

            [lq_sequence, gt_sequence] = generate_sequence( ...
                signal60, S60, pair, mode_mask, SEQUENCE, ...
                ENERGY_BUFFER, stats.Input, stats.GT, ...
                carrier_h, carrier_l);
            save_sequence_png( ...
                LQ_ROOT, GT_ROOT, sequence_name, ...
                lq_sequence, gt_sequence);
            generated_count = generated_count + 1;
        end
        clear raw_data;
    end
end

fprintf('\n数据集生成完成：新增%d条，跳过%d条完整序列。\n', ...
    generated_count, skipped_count);
fprintf('输出目录：%s\n', OUTPUT_ROOT);

%% ============================== 本地函数 =================================
function validate_public_dependencies(repo_root)
%VALIDATE_PUBLIC_DEPENDENCIES 检查脚本允许调用的公共成像函数。
required = ["Range_Compress", "RCMC", "SAR_Imaging", ...
    "minmaxnormalize_image", "quantize_1bit", ...
    "upsample_range_fft", "crop_range_spectrum", ...
    "build_2dsft_threshold", "resolve_range_grid", ...
    "resolve_azimuth_bandwidth", "resolve_pair_grids", ...
    "make_range_sft_pair", "generate_range_2dsft_rc", ...
    "build_2dsft_carrier", "estimate_rc_alignment", ...
    "align_and_mix_rc", "focus_base_rc", ...
    "generate_gt_image", "crop_center"];
for name = required
    expected = fullfile(repo_root, name + ".m");
    if ~isfile(expected) || exist(char(name), 'file') ~= 2
        error('rangeSFTDataset:DependencyMissing', ...
            '缺少公共函数%s：%s。', name, expected);
    end
end
end

function validate_configuration(parameters, sequence, stride_frames, buffer)
%VALIDATE_CONFIGURATION 检查固定九帧协议和生产参数的基本合法性。
parameter_names = ["Method", "QHigh", "QLow", "STRdB", ...
    "FrOverBr", "FaOverBa", "Phi0"];
if ~all(isfield(parameters, parameter_names)) || ...
        string(parameters.Method) ~= "Range_2D_SFT"
    error('rangeSFTDataset:ParameterSchema', ...
        '参数必须完整描述一组Range_2D_SFT配置。');
end
values = [parameters.QHigh, parameters.QLow, parameters.STRdB, ...
    parameters.FrOverBr, parameters.FaOverBa, parameters.Phi0];
if any(~isfinite(values)) || parameters.QHigh <= parameters.QLow || ...
        parameters.QLow < 1 || parameters.FrOverBr < 0 || ...
        parameters.FaOverBa < 0
    error('rangeSFTDataset:ParameterValues', ...
        '必须满足QHigh>QLow>=1，SFT频率非负且所有参数有限。');
end
expected_sequence = struct( ...
    "n_frames", 9, "step", 128, ...
    "signal_height", 1200, "signal_width", 1200, ...
    "patch_size", 512, "roi_size", 600, ...
    "valid_margin", 344, "logic_length", 1536, ...
    "block_width", 2224);
if ~isequaln(sequence, expected_sequence)
    error('rangeSFTDataset:SequenceProtocol', ...
        '数据生成必须使用固定的1200×2224九帧H-L-H协议。');
end
if stride_frames ~= 3 || buffer ~= 64
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
        'compute_range_2dsft_scene_percentiles.m。'], stats_root);
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
scene_key = make_scene_key(scene);
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
verify_stats_protocol(stats.protocol, sequence, buffer, S60, file_path);

parameter_key = make_parameter_key(parameters, stats.protocol);
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
if ~isfield(entry, 'effective_sampling') || ...
        ~all(isfield(entry.effective_sampling, ["H", "L"]))
    error('rangeSFTDataset:SamplingStatsMissing', ...
        '场景%s的统计条目缺少H/L有效采样网格。', scene);
end
verify_effective_grid(entry.effective_sampling.H, grid_h, "H", scene);
verify_effective_grid(entry.effective_sampling.L, grid_l, "L", scene);
validate_normalization_stats(entry.input_stats, "JointHL", stats.protocol);
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

function verify_stats_protocol(protocol, sequence, buffer, S60, file_path)
%VERIFY_STATS_PROTOCOL 确认统计值来自当前生产成像与JointHL协议。
required = ["method", "working_echo", "parameter_file_60", ...
    "low_percentile", "high_percentile", "percentile_method", ...
    "roi_size", "energy_buffer", "joint_pool", ...
    "mixed_pixels_in_pool", "sequence", "imaging"];
if ~all(isfield(protocol, required)) || ...
        string(protocol.method) ~= "Range_2D_SFT" || ...
        string(protocol.working_echo) ~= "60MHz_from_180MHz_stride3" || ...
        string(protocol.percentile_method) ~= "midpoint_exact_tall" || ...
        protocol.roi_size ~= sequence.roi_size || ...
        protocol.energy_buffer ~= buffer || ...
        string(protocol.joint_pool) ~= ...
        "equal_pixels_H_aligned_and_L_all_9_frames" || ...
        logical(protocol.mixed_pixels_in_pool) || ...
        ~isequaln(protocol.sequence, sequence)
    error('rangeSFTDataset:StatsProtocol', ...
        '场景分位数不是当前JointHL生产协议：%s。', file_path);
end
if protocol.low_percentile < 0 || protocol.high_percentile > 100 || ...
        protocol.low_percentile >= protocol.high_percentile
    error('rangeSFTDataset:StatsPercentiles', ...
        '场景分位数协议范围无效：%s。', file_path);
end
if ~strcmpi(string(protocol.parameter_file_60), ...
        string(fullfile(fileparts(mfilename('fullpath')), "FS60_params.mat")))
    error('rangeSFTDataset:StatsParameterFile', ...
        '统计协议使用的FS60参数文件与当前脚本不一致：%s。', file_path);
end
if ~isequaln(protocol.imaging, imaging_parameters(S60))
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
                ~isequaln(loaded.dataset_metadata.signature, signature)
            error('rangeSFTDataset:MetadataMismatch', ...
                '已有输出目录的metadata与当前生产协议不一致：%s。', ...
                output_root);
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

function [lq_sequence, gt_sequence] = generate_sequence( ...
        signal, S60, pair, mask, sequence, buffer, input_stats, gt_stats, ...
        carrier_h, carrier_l)
%GENERATE_SEQUENCE 由一个连续回波块生成配对的九帧LQ和GT。
RC_H = generate_range_2dsft_rc(signal, S60, pair.H, carrier_h);
RC_L = generate_range_2dsft_rc(signal, S60, pair.L, carrier_l);
[RC_mix, ~] = align_and_mix_rc(RC_H, RC_L, mask.full, buffer);

lq_sequence = zeros(sequence.patch_size, sequence.patch_size, ...
    sequence.n_frames, 'uint8');
gt_sequence = zeros(size(lq_sequence), 'uint8');
for frame_idx = 1:sequence.n_frames
    columns = frame_columns(sequence, frame_idx);
    lq_roi = focus_base_rc(RC_mix(:, columns), S60, sequence.roi_size);
    gt_roi = generate_gt_image(signal(:, columns), S60, sequence.roi_size);

    % 必须先在600×600 ROI上使用生产分位数归一化，再中心裁剪到512。
    lq_normalized = minmaxnormalize_image( ...
        lq_roi, input_stats.VMax, input_stats.VMin);
    gt_normalized = minmaxnormalize_image( ...
        gt_roi, gt_stats.VMax, gt_stats.VMin);
    lq_sequence(:, :, frame_idx) = to_uint8_image( ...
        crop_center(lq_normalized, sequence.patch_size));
    gt_sequence(:, :, frame_idx) = to_uint8_image( ...
        crop_center(gt_normalized, sequence.patch_size));
end
end

function mask = build_hlh_mask(sequence)
%BUILD_HLH_MASK 构造H(512)-L(512)-H(512)及两端扩展掩膜。
logic_mask = false(1, sequence.logic_length);
logic_mask(1:512) = true;
logic_mask(1025:1536) = true;
full_mask = [ ...
    repmat(logic_mask(1), 1, sequence.valid_margin), ...
    logic_mask, ...
    repmat(logic_mask(end), 1, sequence.valid_margin)];
boundaries = find(diff(full_mask) ~= 0);
if numel(full_mask) ~= sequence.block_width || numel(boundaries) ~= 2
    error('rangeSFTDataset:HLHMask', ...
        'H-L-H完整掩膜尺寸或边界数量不正确。');
end
mask = struct("logic", logic_mask, "full", full_mask, ...
    "boundaries", boundaries);
end

function columns = frame_columns(sequence, frame_idx)
%FRAME_COLUMNS 返回第frame_idx帧在2224列块中的1200列索引。
start_idx = 1 + (frame_idx - 1) * sequence.step;
columns = start_idx:start_idx + sequence.signal_width - 1;
if columns(end) > sequence.block_width
    error('rangeSFTDataset:FrameColumns', ...
        '第%d帧超出连续回波块。', frame_idx);
end
end

function output = to_uint8_image(input)
%TO_UINT8_IMAGE 将[0,1]归一化结果稳定映射为8-bit灰度图。
input = max(0, min(1, double(input)));
output = uint8(round(input * 255));
end

function state = inspect_sequence_output( ...
        lq_root, gt_root, sequence_name, frame_count)
%INSPECT_SEQUENCE_OUTPUT 完整序列跳过，缺失或不配对状态直接报错。
lq_directory = fullfile(lq_root, sequence_name);
gt_directory = fullfile(gt_root, sequence_name);
lq_exists = isfolder(lq_directory);
gt_exists = isfolder(gt_directory);
if ~lq_exists && ~gt_exists
    state = "missing";
    return;
end
if lq_exists && gt_exists && ...
        has_complete_frames(lq_directory, frame_count) && ...
        has_complete_frames(gt_directory, frame_count)
    state = "complete";
    return;
end
error('rangeSFTDataset:IncompleteSequence', ...
    ['序列%s的LQ/GT输出不完整或不配对。请人工核查后再运行，' ...
    '脚本不会静默覆盖。'], sequence_name);
end

function yes = has_complete_frames(directory, frame_count)
%HAS_COMPLETE_FRAMES 要求目录恰好包含000.png至008.png。
files = dir(fullfile(directory, "*.png"));
actual = sort(lower(string({files.name})));
expected = sort(compose('%03d.png', 0:frame_count-1));
yes = numel(actual) == frame_count && isequal(actual(:), expected(:));
end

function save_sequence_png( ...
        lq_root, gt_root, sequence_name, lq_sequence, gt_sequence)
%SAVE_SEQUENCE_PNG 先写临时目录，九帧均成功后再提交到最终目录。
if ~isequal(size(lq_sequence), size(gt_sequence)) || ...
        size(lq_sequence, 3) ~= 9 || ...
        ~isa(lq_sequence, 'uint8') || ~isa(gt_sequence, 'uint8')
    error('rangeSFTDataset:SequenceImageType', ...
        'LQ/GT必须是同尺寸的uint8九帧序列。');
end
final_lq = fullfile(lq_root, sequence_name);
final_gt = fullfile(gt_root, sequence_name);
temp_lq = string(tempname(lq_root));
temp_gt = string(tempname(gt_root));
ensure_directory(temp_lq);
ensure_directory(temp_gt);
cleanup = onCleanup(@() cleanup_temporary_directories(temp_lq, temp_gt));

for frame_idx = 1:size(lq_sequence, 3)
    name = sprintf('%03d.png', frame_idx - 1);
    imwrite(lq_sequence(:, :, frame_idx), fullfile(temp_lq, name));
    imwrite(gt_sequence(:, :, frame_idx), fullfile(temp_gt, name));
end
if ~has_complete_frames(temp_lq, 9) || ~has_complete_frames(temp_gt, 9)
    error('rangeSFTDataset:TemporarySequence', ...
        '序列%s的临时PNG写出不完整。', sequence_name);
end
if isfolder(final_lq) || isfolder(final_gt)
    error('rangeSFTDataset:SequenceRace', ...
        '提交序列%s时发现同名目标目录。', sequence_name);
end
[ok_gt, message_gt] = movefile(temp_gt, final_gt);
if ~ok_gt
    error('rangeSFTDataset:MoveGT', ...
        '提交GT序列%s失败：%s。', sequence_name, message_gt);
end
[ok_lq, message_lq] = movefile(temp_lq, final_lq);
if ~ok_lq
    error('rangeSFTDataset:MoveLQ', ...
        '提交LQ序列%s失败：%s。', sequence_name, message_lq);
end
clear cleanup;
end

function cleanup_temporary_directories(varargin)
%CLEANUP_TEMPORARY_DIRECTORIES 清理本次尚未提交的临时序列目录。
for idx = 1:nargin
    path = string(varargin{idx});
    if isfolder(path)
        rmdir(path, 's');
    end
end
end

function files = sort_echo_files(files)
%SORT_ECHO_FILES 按rstart后的数值排序，避免字典序打乱轨迹编号。
numbers = inf(numel(files), 1);
for idx = 1:numel(files)
    token = regexp(files(idx).name, ...
        '^rstart\s*([0-9]+)\.mat$', 'tokens', 'once', 'ignorecase');
    if ~isempty(token)
        numbers(idx) = str2double(token{1});
    end
end
names = lower(string({files.name})).';
order = table(numbers, names, (1:numel(files)).', ...
    'VariableNames', ["Number", "Name", "OriginalIndex"]);
order = sortrows(order, ["Number", "Name"]);
files = files(order.OriginalIndex);
end

function name = make_sequence_name(scene_key, rstart_id, c_start)
%MAKE_SEQUENCE_NAME 用数据来源和块起点构造稳定且不冲突的目录名。
name = string(sprintf('%s_rstart_%06d_cstart_%09d', ...
    char(scene_key), rstart_id, c_start));
end

function key = make_scene_key(scene_name)
%MAKE_SCENE_KEY 将七个已知场景映射为稳定ASCII键。
known_names = ["SAR_Dataset_Bangkok_1", "SAR_Dataset_city1_histeq", ...
    "SAR_Dataset_city2_histeq", "SAR_Dataset_SAR_figure", ...
    "SAR_Dataset_filed", "SAR_Dataset_port", "SAR_Dataset_suburb"];
known_keys = ["bangkok", "city1_histeq", "city2_histeq", ...
    "sar_figure", "filed", "port", "suburb"];
index = find(strcmpi(string(scene_name), known_names), 1);
if isempty(index)
    error('rangeSFTDataset:SceneKey', ...
        '不支持的场景名称：%s。', scene_name);
end
key = known_keys(index);
end

function key = make_parameter_key(parameters, protocol)
%MAKE_PARAMETER_KEY 复现分位数脚本使用的完整参数条目键。
key = "range_2d_sft" + ...
    "_qh" + encode_number(parameters.QHigh) + ...
    "_ql" + encode_number(parameters.QLow) + ...
    "_s" + encode_number(parameters.STRdB) + ...
    "_fr" + encode_number(parameters.FrOverBr) + ...
    "_fa" + encode_number(parameters.FaOverBa) + ...
    "_phi" + encode_number(parameters.Phi0) + ...
    "_lp" + encode_number(protocol.low_percentile) + ...
    "_hp" + encode_number(protocol.high_percentile) + ...
    "_roi" + encode_number(protocol.roi_size) + ...
    "_eb" + encode_number(protocol.energy_buffer);
end

function value = encode_number(number)
%ENCODE_NUMBER 将数值稳定编码为ASCII文件键片段。
value = replace(string(sprintf('%.12g', double(number))), "-", "m");
value = replace(value, ".", "p");
value = replace(value, "+", "");
end

function value = imaging_parameters(S60)
%IMAGING_PARAMETERS 提取场景统计协议记录的FS60核心成像参数。
names = ["fc", "B", "Fs", "prf", "R0", "C", "v", ...
    "Tp", "Ta", "nrn", "nan", "R_total", "A_num"];
value = struct();
for name = names
    if isfield(S60, name)
        value.(name) = S60.(name);
    end
end
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
