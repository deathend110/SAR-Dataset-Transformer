function varargout = statistics(action, varargin)
%STATISTICS 共享正式生产的JointHL统计、协议与清单实现。
switch string(action)
    case "build_protocol"
        f = @build_protocol;
    case "validate_parameters"
        f = @validate_parameters;
    case "build_scene_manifest"
        f = @build_scene_manifest;
    case "build_parameter_keys"
        f = @build_parameter_keys;
    case "print_scene_counts"
        f = @print_scene_counts;
    case "load_existing_gt"
        f = @load_existing_gt;
    case "parameter_struct"
        f = @parameter_struct;
    case "scene_entry_exists"
        f = @scene_entry_exists;
    case "process_scene_parameter"
        f = @process_scene_parameter;
    case "upsert_scene_stats"
        f = @upsert_scene_stats;
    case "remove_completed_work_directory"
        f = @remove_completed_work_directory;
    case "ensure_directory"
        f = @ensure_directory;
    case "make_parameter_key"
        f = @make_parameter_key;
    case "make_scene_key"
        f = @make_scene_key;
    case "calculate_chunk_percentiles"
        f = @calculate_chunk_percentiles;
    case "sort_echo_files"
        f = @sort_echo_files;
    otherwise
        error("sarflow:StatisticsAction", "未知统计操作：%s", action);
end
[varargout{1:nargout}] = f(varargin{:});
end

function protocol = build_protocol(cfg, S60, blocks_per_file, ...
        low_percentile, high_percentile, roi_size, energy_buffer)
%BUILD_PROTOCOL 汇总会改变分位数结果的公共统计协议。
% 输入：场景/序列配置、60MHz成像参数、抽样数、分位点、ROI和边界宽度。
% 输出：写入场景MAT和checkpoint的protocol结构，用于显式一致性检查。
protocol = struct( ...
    "method", "Range_2D_SFT", ...
    "working_echo", "60MHz_from_180MHz_stride3", ...
    "parameter_file_60", string(cfg.parameter_file_60), ...
    "low_percentile", low_percentile, ...
    "high_percentile", high_percentile, ...
    "percentile_method", "midpoint_exact_tall", ...
    "roi_size", roi_size, ...
    "blocks_per_file", blocks_per_file, ...
    "block_sampling", "round(linspace(1,max_start,blocks_per_file))", ...
    "energy_buffer", energy_buffer, ...
    "joint_pool", "equal_pixels_H_aligned_and_L_all_9_frames", ...
    "mixed_pixels_in_pool", false, ...
    "sequence", cfg.sequence, ...
    "imaging", imaging_parameters(S60));
end

function validate_parameters(parameters, cfg, S60, protocol)
%VALIDATE_PARAMETERS 检查参数表、归一化范围和SFT物理合法性。
% parameters每行必须完整描述一组H/L倍率及共享2D-SFT参数。
% 本函数不修改参数；任何超Nyquist或重复配置都直接报错。
expected = ["QHigh", "QLow", "STRdB", ...
    "FrOverBr", "FaOverBa", "Phi0"];
if ~isequal(string(parameters.Properties.VariableNames), expected)
    error('scenePercentiles:ParameterSchema', ...
        'PARAMETERS变量名和顺序必须为：%s。', strjoin(expected, ', '));
end
if isempty(parameters)
    error('scenePercentiles:ParametersEmpty', ...
        'PARAMETERS至少需要一行。');
end

values = parameters{:, expected};
if ~isnumeric(values) || any(~isfinite(values), 'all')
    error('scenePercentiles:ParameterValues', ...
        'PARAMETERS必须全部为有限数值。');
end
if any(parameters.QHigh <= parameters.QLow) || ...
        any(parameters.QLow < 1) || ...
        any(parameters.FrOverBr < 0) || any(parameters.FaOverBa < 0)
    error('scenePercentiles:ParameterRanges', ...
        '必须满足QHigh>QLow>=1，且fr/Br、fa/Ba非负。');
end
if protocol.low_percentile < 0 || protocol.high_percentile > 100 || ...
        protocol.low_percentile >= protocol.high_percentile
    error('scenePercentiles:PercentileRange', ...
        '分位数必须满足0<=low<high<=100。');
end
if protocol.roi_size > cfg.sequence.roi_size
    error('scenePercentiles:ROISize', ...
        '统计ROI不能超过现有成像ROI尺寸%d。', cfg.sequence.roi_size);
end

keys = strings(height(parameters), 1);
for idx = 1:height(parameters)
    value = parameter_struct(parameters(idx, :));
    pair = make_range_sft_pair(value);
    resolve_pair_grids(pair, cfg.sequence, S60, cfg.nyquist_margin);
    keys(idx) = make_parameter_key(value, protocol);
end
if numel(unique(keys)) ~= numel(keys)
    error('scenePercentiles:DuplicateParameters', ...
        'PARAMETERS中存在重复的完整参数行。');
end
end

function keys = build_parameter_keys(parameters, protocol)
%BUILD_PARAMETER_KEYS 为参数表逐行生成稳定、可读且不冲突的文件键。
% 键中包含倍率、SFT参数和归一化协议，防止统计量被错误复用。
keys = strings(height(parameters), 1);
for idx = 1:height(parameters)
    keys(idx) = make_parameter_key( ...
        parameter_struct(parameters(idx, :)), protocol);
end
end

function parameters = parameter_struct(row)
%PARAMETER_STRUCT 将单行table转换为便于函数传递的标量结构。
% 输出字段保留物理名称和double类型，避免table标量类型扩散。
parameters = struct( ...
    "Method", "Range_2D_SFT", ...
    "QHigh", double(row.QHigh), ...
    "QLow", double(row.QLow), ...
    "STRdB", double(row.STRdB), ...
    "FrOverBr", double(row.FrOverBr), ...
    "FaOverBa", double(row.FaOverBa), ...
    "Phi0", double(row.Phi0));
end

function result = process_scene_parameter(cfg, S60, scene_manifest, ...
        pair, parameters, protocol, work_directory, need_gt, ...
        carrier_h, carrier_l, max_in_memory_percentile_gb, ...
        enable_in_memory_percentile)
%PROCESS_SCENE_PARAMETER 计算一个场景、一组参数的JointHL分位数。
% scene_manifest包含该场景全部均匀抽样序列；pair定义H/L采集分支。
% need_gt=true时在同一遍历中同步收集GT像素，避免额外读取和成像。
% 输出result包含JointHL输入统计、可选GT统计和能量对齐审计量。
% 大像素池按序列写入chunk，避免将整个场景一次性保存在内存中。
joint_directory = fullfile(work_directory, "joint");
gt_directory = fullfile(work_directory, "gt");
checkpoint_path = fullfile(work_directory, "checkpoint.mat");
ensure_directory(joint_directory);
if need_gt
    ensure_directory(gt_directory);
end

% checkpoint_config保存显式配置和完整清单，不使用哈希或摘要。
checkpoint_config = struct( ...
    "version", "range_2dsft_scene_percentiles_checkpoint_v2", ...
    "scene", string(scene_manifest.Scene(1)), ...
    "manifest", scene_manifest, ...
    "parameters", parameters, ...
    "protocol", protocol, ...
    "include_gt", need_gt);
sequence_count = height(scene_manifest); % 当前场景参与统计的连续序列数
% 每条序列完成后记录gamma和边界残差，便于恢复及最终审计。
initial_state = struct( ...
    "config", checkpoint_config, ...
    "completed_sequences", 0, ...
    "scale_factors", nan(sequence_count, 1), ...
    "boundary_jump_db", nan(sequence_count, 1));
state = load_checkpoint(checkpoint_path, checkpoint_config, initial_state);
verify_completed_chunks( ...
    state.completed_sequences, joint_directory, gt_directory, need_gt);

frame_count = cfg.sequence.n_frames;       % 固定九帧
pixels_per_image = protocol.roi_size ^ 2; % 单张600×600 ROI的像素数
mask = sarflow.build_hlh_mask(cfg.sequence);
for sequence_idx = state.completed_sequences + 1:sequence_count
    signal = sarflow.load_echo_block( ...
        scene_manifest(sequence_idx, :), S60, cfg.sequence.block_width);
    if isreal(signal) || ~isequal(size(signal), ...
            [cfg.sequence.signal_height, cfg.sequence.block_width])
        error('scenePercentiles:InvalidEchoBlock', ...
            '序列%d的60MHz复回波尺寸不正确。', ...
            scene_manifest.SequenceID(sequence_idx));
    end

    % 同一连续回波分别生成H/L完整RC；二者共享SFT物理参数。
    [~, mix_info, RC_H, RC_L] = sarflow.mix_sequence_rc( ...
        signal, S60, pair, mask.full, protocol.energy_buffer, carrier_h, carrier_l);

    % 每帧贡献一张H和一张L，因此JointHL像素数严格为GT的两倍。
    joint_values = zeros(2 * pixels_per_image * frame_count, 1, 'single');
    if need_gt
        gt_values = zeros(pixels_per_image * frame_count, 1, 'single');
    end
    for frame_idx = 1:frame_count
        % 九个1200列成像窗口沿2224列连续块每次移动128列。
        columns = sarflow.frame_columns(cfg.sequence, frame_idx);
        h_image = focus_base_rc( ...
            RC_H(:, columns), S60, protocol.roi_size);
        l_image = focus_base_rc( ...
            RC_L(:, columns), S60, protocol.roi_size);
        frame_pool = make_joint_hl_pool(h_image, l_image); % H/L等像素权重
        % 将当前帧的2×600×600像素写入预分配列向量对应区间。
        joint_start = (frame_idx - 1) * 2 * pixels_per_image + 1;
        joint_stop = frame_idx * 2 * pixels_per_image;
        joint_values(joint_start:joint_stop) = frame_pool;

        if need_gt
            gt_image = generate_gt_image( ...
                signal(:, columns), S60, protocol.roi_size);
            gt_start = (frame_idx - 1) * pixels_per_image + 1;
            gt_stop = frame_idx * pixels_per_image;
            gt_values(gt_start:gt_stop) = single(gt_image(:));
        end
    end

    % chunk编号与场景清单行一一对应，保证断点恢复顺序确定。
    chunk_name = sprintf('chunk_%06d.mat', sequence_idx);
    atomic_save(fullfile(joint_directory, chunk_name), ...
        struct("values", joint_values));
    if need_gt
        atomic_save(fullfile(gt_directory, chunk_name), ...
            struct("values", gt_values));
    end
    % 先完整写出像素chunk，再更新checkpoint，避免声明完成但文件缺失。
    state.completed_sequences = sequence_idx;
    state.scale_factors(sequence_idx) = mix_info.scale_factor;
    state.boundary_jump_db(sequence_idx) = mix_info.boundary_jump_db;
    atomic_save(checkpoint_path, struct("state", state));
    fprintf('    序列 %d/%d 完成。\n', sequence_idx, sequence_count);
end

% 所有序列完成后，跨全部chunk计算场景级精确分位数。
percentages = [protocol.low_percentile, protocol.high_percentile];
input_stats = calculate_chunk_percentiles( ...
    joint_directory, percentages, "JointHL", ...
    2 * sequence_count * frame_count, pixels_per_image, ...
    max_in_memory_percentile_gb, sequence_count, enable_in_memory_percentile);

if need_gt
    gt_stats = calculate_chunk_percentiles( ...
        gt_directory, percentages, "GT", sequence_count * frame_count, ...
        pixels_per_image, max_in_memory_percentile_gb, sequence_count, ...
        enable_in_memory_percentile);
else
    gt_stats = struct();
end

% audit不参与归一化，只用于检查gamma范围和RC边界是否仍接近0 dB。
audit = struct( ...
    "SequenceCount", sequence_count, ...
    "FileCount", numel(unique(scene_manifest.FilePath)), ...
    "BlocksPerFile", protocol.blocks_per_file, ...
    "ScaleFactorMin", min(state.scale_factors), ...
    "ScaleFactorMean", mean(state.scale_factors), ...
    "ScaleFactorMax", max(state.scale_factors), ...
    "MaxAbsBoundaryJumpDB", max(abs(state.boundary_jump_db)), ...
    "CompletedSequences", state.completed_sequences);
if any(~isfinite([audit.ScaleFactorMin, audit.ScaleFactorMean, ...
        audit.ScaleFactorMax, audit.MaxAbsBoundaryJumpDB]))
    error('scenePercentiles:NonfiniteAudit', ...
        '场景统计审计量中存在非有限值。');
end
result = struct("input_stats", input_stats, ...
    "gt_stats", gt_stats, "audit", audit);
end

function verify_completed_chunks(completed, joint_dir, gt_dir, need_gt)
%VERIFY_COMPLETED_CHUNKS 核对checkpoint声称完成的磁盘像素块。
% JointHL chunk必须存在；need_gt=true时对应GT chunk也必须存在。
for idx = 1:completed
    name = sprintf('chunk_%06d.mat', idx);
    if ~isfile(fullfile(joint_dir, name)) || ...
            (need_gt && ~isfile(fullfile(gt_dir, name)))
        error('scenePercentiles:CheckpointChunkMissing', ...
            'checkpoint声明完成的chunk缺失：%s', name);
    end
end
end

function gt_stats = load_existing_gt(file_path, header)
%LOAD_EXISTING_GT 从已有场景MAT读取可复用的GT分位数。
% 复用前直接比较schema、场景身份、完整协议和源清单，不使用哈希。
% 文件不存在时返回空结构，主流程会在首个参数中计算GT。
gt_stats = struct();
if ~isfile(file_path)
    return;
end
loaded = load(file_path, 'scene_stats');
if ~isfield(loaded, 'scene_stats')
    error('scenePercentiles:SceneFileSchema', ...
        '已有MAT缺少scene_stats：%s', file_path);
end
existing = loaded.scene_stats;
required = ["schema_version", "scene_name", "scene_key", ...
    "protocol", "source_manifest", "gt"];
if ~all(isfield(existing, required)) || ...
        string(existing.schema_version) ~= string(header.schema_version) || ...
        string(existing.scene_name) ~= string(header.scene_name) || ...
        string(existing.scene_key) ~= string(header.scene_key) || ...
        ~isequaln(existing.protocol, header.protocol) || ...
        ~isequaln(existing.source_manifest, header.source_manifest)
    error('scenePercentiles:SceneSourceMismatch', ...
        '已有场景MAT与当前数据或协议不一致：%s', file_path);
end
gt_stats = existing.gt;
end

function exists = scene_entry_exists(file_path, parameter_key)
%SCENE_ENTRY_EXISTS 判断指定参数的JointHL统计是否已经成功提交。
% 返回true时主流程跳过重复成像，并清理可能残留的临时目录。
exists = false;
if ~isfile(file_path)
    return;
end
loaded = load(file_path, 'scene_stats');
if ~isfield(loaded, 'scene_stats') || ...
        ~isfield(loaded.scene_stats, 'entries') || ...
        isempty(loaded.scene_stats.entries)
    return;
end
keys = string({loaded.scene_stats.entries.parameter_key});
exists = any(keys == string(parameter_key));
end

function value = imaging_parameters(S60)
%IMAGING_PARAMETERS 提取会影响成像和分位数的FS60核心参数。
% 这些显式字段随protocol保存，用于后续逐字段一致性检查。
names = ["fc", "B", "Fs", "prf", "R0", "C", "v", ...
    "Tp", "Ta", "nrn", "nan", "R_total", "A_num"];
value = struct();
for name = names
    if isfield(S60, name)
        value.(name) = S60.(name);
    end
end
end

function manifest = build_scene_manifest(cfg, blocks_per_file)
%BUILD_SCENE_MANIFEST 枚举全部场景轨迹并建立确定性的统计清单。
% 每个rstart文件在[1,max_start]内均匀选取blocks_per_file个CStart。
% 输出manifest逐行记录场景、文件、变量、起点和文件元数据，既用于
% 主循环读取，也用于已有结果和checkpoint的显式一致性比较。
manifest = table();
sequence_id = 0; % 跨场景递增的唯一序列编号
for scene_idx = 1:numel(cfg.dataset_names)
    scene = string(cfg.dataset_names(scene_idx));
    scene_directory = fullfile(string(cfg.data_root), scene);
    if ~isfolder(scene_directory)
        error('scenePercentiles:SceneDirectoryMissing', ...
            '场景目录不存在：%s', scene_directory);
    end

    files = sort_echo_files(dir(fullfile(scene_directory, "rstart*.mat")));
    if isempty(files)
        error('scenePercentiles:EchoFilesMissing', ...
            '场景%s中没有rstart*.mat。', scene);
    end
    scene_key = make_scene_key(scene);

    for file_idx = 1:numel(files)
        file = files(file_idx);
        file_path = string(fullfile(file.folder, file.name));
        variables = whos('-file', file_path);
        if isempty(variables) || numel(variables(1).size) ~= 2
            error('scenePercentiles:EchoSchema', ...
                '回波文件缺少二维变量：%s', file_path);
        end
        raw_width = variables(1).size(2); % 180MHz原始回波总列数
        max_start = raw_width - cfg.sequence.block_width + 1; % 最大合法首列
        if max_start < blocks_per_file
            error('scenePercentiles:EchoTooShort', ...
                '文件%s无法抽取%d个宽度为%d的不同连续块。', ...
                file.name, blocks_per_file, cfg.sequence.block_width);
        end
        % 包含轨迹首尾位置，round后仍要求所有起点互不重复。
        starts = unique(round(linspace(1, max_start, blocks_per_file)), ...
            'stable');
        if numel(starts) ~= blocks_per_file
            error('scenePercentiles:StartsNotUnique', ...
                '文件%s无法得到%d个不同的均匀起点。', ...
                file.name, blocks_per_file);
        end

        for block_idx = 1:blocks_per_file
            sequence_id = sequence_id + 1;
            SequenceID = sequence_id;
            SceneIdx = scene_idx;
            Scene = scene;
            SceneKey = scene_key;
            FileIdx = file_idx;
            File = string(file.name);
            FilePath = file_path;
            EchoVariable = string(variables(1).name);
            CStart = starts(block_idx);
            BlockWidth = cfg.sequence.block_width;
            RawWidth = raw_width;
            BlockIndex = block_idx;
            FileBytes = double(file.bytes);
            FileDatenum = double(file.datenum);
            row = table(SequenceID, SceneIdx, Scene, SceneKey, FileIdx, ...
                File, FilePath, EchoVariable, CStart, BlockWidth, RawWidth, ...
                BlockIndex, FileBytes, FileDatenum);
            manifest = append_table(manifest, row);
        end
    end
end
end

function files = sort_echo_files(files)
%SORT_ECHO_FILES 按rstart后的数字对轨迹文件进行稳定排序。
% 例如rstart 20.mat排在rstart 100.mat前；无法解析时按名称排序。
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

function key = make_scene_key(scene_name)
%MAKE_SCENE_KEY 将场景全名转换为稳定、可读的MAT文件名。
% 已知七场景使用固定映射，未知名称再执行小写和安全字符清理。
known_names = ["SAR_Dataset_Bangkok_1", "SAR_Dataset_city1_histeq", ...
    "SAR_Dataset_city2_histeq", "SAR_Dataset_SAR_figure", ...
    "SAR_Dataset_filed", "SAR_Dataset_port", "SAR_Dataset_suburb"];
known_keys = ["bangkok", "city1_histeq", "city2_histeq", ...
    "sar_figure", "filed", "port", "suburb"];
index = find(strcmpi(string(scene_name), known_names), 1);
if ~isempty(index)
    key = known_keys(index);
    return;
end
key = lower(regexprep(string(scene_name), '^SAR_Dataset_', ''));
key = strip(regexprep(key, '[^a-z0-9_]+', '_'), '_');
if strlength(key) == 0
    error('scenePercentiles:InvalidSceneKey', ...
        '场景名称无法转换为文件键：%s', scene_name);
end
end

function values = make_joint_hl_pool(h_image, l_image)
%MAKE_JOINT_HL_POOL 将一张纯H和一张纯L幅度图等权连接。
% h_image必须已经乘过当前序列的gamma；这里不做像素融合或加权平均。
% 输出顺序为[H(:);L(:)]，相同尺寸天然保证H/L像素权重各占50%。
if ~isequal(size(h_image), size(l_image)) || ...
        ~isreal(h_image) || ~isreal(l_image)
    error('scenePercentiles:JointHLImageMismatch', ...
        'JointHL要求H/L为同尺寸实数幅度图。');
end
values = [single(h_image(:)); single(l_image(:))];
end

function stats = calculate_chunk_percentiles( ...
        chunk_directory, percentages, modality, image_count, ...
        pixels_per_image, max_in_memory_percentile_gb, ...
        expected_chunk_count, enable_in_memory_percentile)
%CALCULATE_CHUNK_PERCENTILES 使用精确memory或tall路径计算场景级分位数。
% 两条路径都使用全部single像素和midpoint插值；backend只记录运行审计。
files = dir(fullfile(chunk_directory, "chunk_*.mat"));
[~, order] = sort(lower(string({files.name})));
files = files(order);
if isempty(files)
    error('scenePercentiles:PercentileChunksMissing', ...
        '没有找到分位数数据块：%s', chunk_directory);
end
if numel(files) ~= expected_chunk_count
    error('scenePercentiles:ChunkCountMismatch', ...
        'chunk数量%d与协议预期%d不一致：%s', ...
        numel(files), expected_chunk_count, chunk_directory);
end

paths = strings(numel(files), 1); % 按chunk编号排序后的完整路径
for idx = 1:numel(files)
    paths(idx) = string(fullfile(files(idx).folder, files(idx).name));
end
pixel_count = double(image_count) * double(pixels_per_image);
if ~isfinite(pixel_count) || pixel_count <= 0 || pixel_count ~= fix(pixel_count)
    error('scenePercentiles:PixelCount', ...
        '理论像素数量必须是正整数。');
end
max_bytes = double(max_in_memory_percentile_gb) * 1024 ^ 3;
if ~isfinite(max_bytes) || max_bytes <= 0
    error('scenePercentiles:PercentileMemoryLimit', ...
        'memory percentile容量上限必须为正数。');
end

if enable_in_memory_percentile && pixel_count * 4 <= max_bytes
    all_values = zeros(pixel_count, 1, 'single');
    cursor = 1;
    for idx = 1:numel(paths)
        chunk_values = read_chunk_values(paths(idx));
        next_cursor = cursor + numel(chunk_values) - 1;
        if next_cursor > pixel_count
            error('scenePercentiles:PixelCountMismatch', ...
                'chunk像素数量超过协议预期：%s', paths(idx));
        end
        all_values(cursor:next_cursor) = chunk_values;
        cursor = next_cursor + 1;
        clear chunk_values
    end
    if cursor - 1 ~= pixel_count
        error('scenePercentiles:PixelCountMismatch', ...
            'chunk像素数量与协议预期不一致。');
    end
    limits = prctile(all_values, percentages, Method="midpoint");
    backend = "memory";
    clear all_values
else
    % 每次只读取一个single列向量，tall在本地MATLAB会话中顺序汇总。
    datastore_value = fileDatastore(paths, ...
        'ReadFcn', @read_chunk_values, 'UniformRead', true);
    mapreducer(0); % 使用本地MATLAB会话，不依赖并行许可证。
    tall_values = tall(datastore_value);
    limits = gather(prctile(tall_values, percentages, Method="midpoint"));
    backend = "tall";
    clear datastore_value tall_values
end
limits = double(limits(:));
if numel(limits) ~= 2 || any(~isfinite(limits)) || limits(2) <= limits(1)
    error('scenePercentiles:DegeneratePercentiles', ...
        '%s分位数范围无效。', modality);
end
stats = struct("Modality", modality, "VMin", limits(1), ...
    "VMax", limits(2), "ImageCount", image_count, ...
    "PixelCount", pixel_count, "ChunkCount", numel(files), ...
    "LowPercentile", percentages(1), ...
    "HighPercentile", percentages(2), ...
    "Method", "midpoint_exact_tall", "Backend", backend);
end

function values = read_chunk_values(file_path)
%READ_CHUNK_VALUES fileDatastore的单文件读取函数。
% 每个chunk只允许包含一个名为values的列向量。
loaded = load(file_path, 'values');
if ~isfield(loaded, 'values')
    error('scenePercentiles:ChunkSchema', ...
        '数据块缺少values变量：%s', file_path);
end
values = loaded.values;
if ~isa(values, 'single') || ~ismatrix(values) || ...
        size(values, 2) ~= 1
    error('scenePercentiles:ChunkType', ...
        'chunk.values必须是single列向量：%s', file_path);
end
end

function key = make_parameter_key(parameters, protocol)
%MAKE_PARAMETER_KEY 构造一套统计结果的稳定ASCII条目键。
% 倍率、STR、fr、fa、phi0、分位点、ROI和buffer全部进入键，避免误用。
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
%ENCODE_NUMBER 将数值转换为适合文件键的ASCII片段。
% 负号编码为m，小数点编码为p，避免不同平台文件名歧义。
value = replace(string(sprintf('%.12g', double(number))), "-", "m");
value = replace(value, ".", "p");
value = replace(value, "+", "");
end

function scene_stats = upsert_scene_stats( ...
        file_path, header, gt_stats, entry)
%UPSERT_SCENE_STATS 原子新增或替换场景MAT中的一组参数统计。
% 一个MAT保存场景共享GT以及多组Range+2D-SFT JointHL输入分位数。
% parameter_key唯一匹配；重复运行同一参数时保留created_at并更新时间。
now_text = string(datetime('now', ... % 当前结果写入时间，使用带时区ISO格式
    'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
if isfile(file_path)
    loaded = load(file_path, 'scene_stats');
    if ~isfield(loaded, 'scene_stats')
        error('scenePercentiles:SceneFileSchema', ...
            'MAT文件缺少scene_stats：%s', file_path);
    end
    scene_stats = loaded.scene_stats;
    verify_scene_header(scene_stats, header, file_path);
else
    scene_stats = header;
    scene_stats.gt = gt_stats;
    scene_stats.entries = struct([]);
    scene_stats.created_at = now_text;
end

entry.updated_at = now_text;
keys = strings(0, 1); % 已有entries的parameter_key列表
if ~isempty(scene_stats.entries)
    keys = string({scene_stats.entries.parameter_key}).';
end
match = find(keys == string(entry.parameter_key));
if numel(match) > 1
    error('scenePercentiles:DuplicateParameterKey', ...
        '场景MAT中存在重复参数键：%s', entry.parameter_key);
elseif isempty(match)
    entry.created_at = now_text;
    if isempty(scene_stats.entries)
        scene_stats.entries = entry;
    else
        scene_stats.entries(end + 1) = entry;
    end
else
    entry.created_at = scene_stats.entries(match).created_at;
    scene_stats.entries(match) = entry;
end
scene_stats.updated_at = now_text;
atomic_save(file_path, struct("scene_stats", scene_stats));
end

function verify_scene_header(scene_stats, header, file_path)
%VERIFY_SCENE_HEADER 防止新统计写入不兼容的已有场景MAT。
% 直接逐字段比较场景身份、统计协议和完整源清单，不计算哈希。
required = ["schema_version", "scene_name", "scene_key", ...
    "protocol", "source_manifest", "gt", "entries", "created_at"];
if ~all(isfield(scene_stats, required)) || ...
        string(scene_stats.schema_version) ~= string(header.schema_version) || ...
        string(scene_stats.scene_name) ~= string(header.scene_name) || ...
        string(scene_stats.scene_key) ~= string(header.scene_key) || ...
        ~isequaln(scene_stats.protocol, header.protocol) || ...
        ~isequaln(scene_stats.source_manifest, header.source_manifest)
    error('scenePercentiles:SceneSourceMismatch', ...
        '已有场景MAT与当前数据清单或协议不一致：%s', file_path);
end
end

function output = append_table(input, row)
%APPEND_TABLE 将单行table安全追加到table累加器。
% 空累加器必须初始化为table()，避免table与double空数组混合拼接。
if isempty(input)
    output = row;
else
    output = [input; row];
end
end

function ensure_directory(path)
%ENSURE_DIRECTORY 确保输出或临时目录存在；创建失败立即报错。
if ~isfolder(path)
    [ok, message] = mkdir(path);
    if ~ok
        error('scenePercentiles:CreateDirectory', ...
            '无法创建目录%s：%s', path, message);
    end
end
end

function state = load_checkpoint(file_path, checkpoint_config, initial_state)
%LOAD_CHECKPOINT 恢复长时间统计的序列级进度。
% 不计算哈希；直接保存并逐字段比较完整配置和场景清单。
% 文件不存在时返回initial_state，配置不一致时拒绝静默复用。
state = initial_state;
if ~isfile(file_path)
    return;
end
loaded = load(file_path, 'state');
if ~isfield(loaded, 'state') || ~isfield(loaded.state, 'config')
    error('scenePercentiles:CheckpointSchema', ...
        'checkpoint缺少完整配置：%s', file_path);
end
if ~isequaln(loaded.state.config, checkpoint_config)
    error('scenePercentiles:CheckpointConfigMismatch', ...
        'checkpoint配置或场景清单与当前运行不一致：%s', file_path);
end
state = loaded.state;
end

function atomic_save(file_path, payload)
%ATOMIC_SAVE 先写临时MAT，再替换目标文件。
% payload为待保存结构；先完整写入.tmp可避免中断留下半写结果。
output_directory = string(fileparts(file_path));
if strlength(output_directory) > 0
    ensure_directory(output_directory);
end
temporary_path = string(file_path) + ".tmp"; % 与目标文件同目录，便于原子替换
save(temporary_path, '-struct', 'payload', '-v7.3');
[ok, message] = movefile(temporary_path, file_path, 'f');
if ~ok
    error('scenePercentiles:AtomicMove', ...
        '无法更新%s：%s', file_path, message);
end
end

function print_scene_counts(manifest)
%PRINT_SCENE_COUNTS 在正式计算前打印每个场景的文件数和序列数。
scenes = unique(string(manifest.Scene), 'stable');
for idx = 1:numel(scenes)
    rows = manifest(string(manifest.Scene) == scenes(idx), :);
    fprintf('  %-28s 文件=%d，序列=%d\n', scenes(idx), ...
        numel(unique(rows.FilePath)), height(rows));
end
end

function remove_completed_work_directory(work_directory, work_root)
%REMOVE_COMPLETED_WORK_DIRECTORY 删除已提交结果对应的临时chunk目录。
% 删除前解析规范绝对路径，并强制要求目标位于_work根目录内部。
% 最终场景MAT已原子写入，因此这里只清理可再生的临时文件。
if ~isfolder(work_directory)
    return;
end
canonical_work = string(java.io.File(char(work_directory)).getCanonicalPath());
canonical_root = string(java.io.File(char(work_root)).getCanonicalPath());
expected_prefix = canonical_root + string(filesep);
if canonical_work == canonical_root || ...
        ~startsWith(canonical_work, expected_prefix)
    error('scenePercentiles:UnsafeWorkCleanup', ...
        '拒绝清理工作目录之外的路径：%s', canonical_work);
end
[ok, message] = rmdir(canonical_work, 's');
if ~ok
    warning('scenePercentiles:WorkCleanupFailed', ...
        '结果已提交，但临时目录清理失败：%s', message);
end
end
