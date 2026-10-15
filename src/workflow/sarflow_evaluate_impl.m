function results_table = sarflow_evaluate_impl(cfg, PARAMETER_KEY)
%RUN_RANGE_2DSFT_EVALUATE 可调用的全量PNG指标入口。
setup_range_2dsft_paths(cfg);
paths = sarflow_paths(cfg);
SCRIPT_PATH = fullfile(cfg.repo_root, "run_range_2dsft_evaluate");
DATASET_PARENT = paths.dataset;
PARALLEL_WORKERS = cfg.evaluate.workers;
CHUNK_SIZE = cfg.evaluate.chunk_size;
FORCE_RERUN = false;
N_FRAMES = cfg.sequence.n_frames;
%% ========================== 预检与数据集发现 =============================
validate_metric_toolbox();
[dataset_root, parameter_key] = resolve_dataset_root( ...
    DATASET_PARENT, PARAMETER_KEY);
fprintf('评估数据集：%s\n', dataset_root);
fprintf('参数键：%s\n', parameter_key);

dataset_signature = load_dataset_signature(dataset_root);
[all_names, scene_keys, rstart_ids, cstart_ids] = ...
    collect_sequences(dataset_root, N_FRAMES);
fprintf('共发现%d条配对完整的LQ/GT序列。\n', numel(all_names));

RESULTS_ROOT = fullfile(paths.evaluation,parameter_key);
ensure_directory(RESULTS_ROOT);
checkpoint_path = fullfile(paths.checkpoints,"evaluation",parameter_key,"checkpoint.mat");
ensure_directory(fileparts(checkpoint_path));

% checkpoint签名包含全部序列名，数据集任何变化都会导致恢复失败
signature = struct( ...
    "schema_version", "range_2dsft_psnr_ssim_v1", ...
    "script", SCRIPT_PATH, ...
    "dataset_root", string(dataset_root), ...
    "parameter_key", string(parameter_key), ...
    "n_frames", N_FRAMES, ...
    "metric_psnr", "psnr_builtin_uint8", ...
    "metric_ssim", "ssim_builtin_uint8", ...
    "sequence_names", all_names);
signature.dataset_signature = dataset_signature;

%% ========================= checkpoint恢复判断 ============================
results_table = empty_results_table(N_FRAMES);
if ~FORCE_RERUN && isfile(checkpoint_path)
    loaded = load(char(checkpoint_path), 'signature', 'results_table');
    if ~isfield(loaded, 'signature') || ~isfield(loaded, 'results_table') || ...
            ~isequaln(loaded.signature, signature)
        error('rangeSFTMetrics:CheckpointMismatch', ...
            ['checkpoint签名与当前数据集或评估协议不一致，' ...
            '不能静默复用旧结果：%s。'], checkpoint_path);
    end
    results_table = loaded.results_table;
    validate_checkpoint_results(results_table, all_names, scene_keys, ...
        rstart_ids, cstart_ids, N_FRAMES);
    fprintf('从checkpoint恢复：%d条序列已完成。\n', height(results_table));
% 进入elseif说明checkpoint存在但FORCE_RERUN=true，忽略旧结果
elseif isfile(checkpoint_path)
    fprintf('FORCE_RERUN=true，忽略已有checkpoint，从头计算。\n');
end

completed_names = string(results_table.SequenceName);
pending_mask = ~ismember(all_names, completed_names);
pending_global_indices = find(pending_mask);
total_count = numel(all_names);
done_count = total_count - numel(pending_global_indices);
fprintf('待计算：%d条，已完成：%d条。\n', ...
    numel(pending_global_indices), done_count);

%% ====================== 主循环：chunked parfor计算 =======================
[use_parallel, workers_used] = setup_parallel_pool(PARALLEL_WORKERS);
if use_parallel
    fprintf('并行计算：%d个worker，块大小%d。\n', workers_used, CHUNK_SIZE);
else
    fprintf('串行计算，块大小%d。\n', CHUNK_SIZE);
end

for chunk_start = 1:CHUNK_SIZE:numel(pending_global_indices)
    % 块位置先映射回全局索引，保证断点恢复后名称与元数据仍严格对应
    chunk_positions = chunk_start:min(chunk_start + CHUNK_SIZE - 1, ...
        numel(pending_global_indices));
    chunk_global_indices = pending_global_indices(chunk_positions);
    chunk_names = all_names(chunk_global_indices);
    chunk_count = numel(chunk_names);

    % 块内预分配数值矩阵，parfor按行切片写入，避免循环内增长table
    psnr_block = nan(chunk_count, N_FRAMES);
    ssim_block = nan(chunk_count, N_FRAMES);
    if use_parallel
        parfor seq_idx = 1:chunk_count
            [psnr_block(seq_idx, :), ssim_block(seq_idx, :)] = ...
                evaluate_sequence(dataset_root, chunk_names(seq_idx), ...
                N_FRAMES);
        end
    else
        for seq_idx = 1:chunk_count
            [psnr_block(seq_idx, :), ssim_block(seq_idx, :)] = ...
                evaluate_sequence(dataset_root, chunk_names(seq_idx), ...
                N_FRAMES);
        end
    end

    % 按块构造与累计table同构的行块后拼接，再原子保存checkpoint
    chunk_rows = make_rows_table(chunk_names, ...
        scene_keys(chunk_global_indices), rstart_ids(chunk_global_indices), ...
        cstart_ids(chunk_global_indices), psnr_block, ssim_block, N_FRAMES);
    results_table = [results_table; chunk_rows]; %#ok<AGROW>
    atomic_save_checkpoint(checkpoint_path, signature, results_table);
    done_count = done_count + chunk_count;
    fprintf('进度：%d/%d条序列已完成。\n', done_count, total_count);
end

%% ============================ 结果整理与校验 =============================
results_table = sortrows(results_table, "SequenceName");
if height(results_table) ~= total_count
    error('rangeSFTMetrics:RowCountMismatch', ...
        '结果行数%d与序列总数%d不一致。', height(results_table), total_count);
end

psnr_matrix = extract_frame_matrix(results_table, "PSNR_Frame", N_FRAMES);
ssim_matrix = extract_frame_matrix(results_table, "SSIM_Frame", N_FRAMES);
bad_mask = ~all(isfinite(psnr_matrix), 2) | ~all(isfinite(ssim_matrix), 2);
if any(bad_mask)
    bad_names = join(results_table.SequenceName(bad_mask), ", ");
    error('rangeSFTMetrics:NonFiniteMetric', ...
        '以下序列存在非有限指标值，禁止写出：%s。', bad_names);
end

% 序列单位统计量：九帧算术平均
results_table.PSNR_Mean = mean(psnr_matrix, 2);
results_table.SSIM_Mean = mean(ssim_matrix, 2);

% 曲线统计量：各帧位置全体序列平均（PSNR为dB域平均，1×9行向量）
frame_axis = 0:N_FRAMES - 1;
psnr_curve_mean = mean(psnr_matrix, 1);
psnr_curve_std = std(psnr_matrix, 0, 1);
ssim_curve_mean = mean(ssim_matrix, 1);
ssim_curve_std = std(ssim_matrix, 0, 1);

%% ============================== 结果落盘 ================================
first_frame = imread(fullfile(dataset_root, "LQ", ...
    results_table.SequenceName(1), "000.png"));
[scene_list, ~, scene_map] = unique(results_table.SceneKey);
evaluation_metadata = struct( ...
    "schema_version", "range_2dsft_psnr_ssim_v1", ...
    "script", SCRIPT_PATH, ...
    "created_at", string(datetime('now', ...
    'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSSXXX')), ...
    "dataset_root", string(dataset_root), ...
    "parameter_key", string(parameter_key), ...
    "sequence_count", height(results_table), ...
    "scenes", scene_list, ...
    "scene_sequence_counts", accumarray(scene_map, 1), ...
    "n_frames", N_FRAMES, ...
    "frame_size", [size(first_frame, 1), size(first_frame, 2)], ...
    "metric_psnr", "MATLAB psnr()，uint8动态范围[0,255]", ...
    "metric_ssim", "MATLAB ssim()，uint8动态范围[0,255]", ...
    "averaging", "序列均值=9帧算术平均；曲线=各帧位置全体序列平均（PSNR为dB域平均）", ...
    "matlab_version", string(version), ...
    "parallel_workers", workers_used, ...
    "dataset_signature", dataset_signature);

csv_path = fullfile(RESULTS_ROOT, ...
    "psnr_ssim_statistics_" + parameter_key + ".csv");
mat_path = fullfile(RESULTS_ROOT, ...
    "psnr_ssim_statistics_" + parameter_key + ".mat");
psnr_png_path = fullfile(RESULTS_ROOT, ...
    "psnr_curve_" + parameter_key + ".png");
ssim_png_path = fullfile(RESULTS_ROOT, ...
    "ssim_curve_" + parameter_key + ".png");

writetable(results_table, csv_path);
save(char(mat_path), 'results_table', 'evaluation_metadata');

plot_metric_curve(frame_axis, psnr_curve_mean, psnr_curve_std, ...
    "PSNR (dB)", sprintf('PSNR曲线（LQ vs GT，%d条序列）', total_count), ...
    psnr_png_path);
plot_metric_curve(frame_axis, ssim_curve_mean, ssim_curve_std, ...
    "SSIM", sprintf('SSIM曲线（LQ vs GT，%d条序列）', total_count), ...
    ssim_png_path);

fprintf(['评估完成：%d条序列。PSNR均值=%.2f dB，' ...
    'SSIM均值=%.4f。\n'], total_count, ...
    mean(results_table.PSNR_Mean), mean(results_table.SSIM_Mean));
fprintf('结果目录：%s\n', RESULTS_ROOT);

%% ============================== 本地函数 =================================
end

function validate_metric_toolbox()
%VALIDATE_METRIC_TOOLBOX 确认psnr/ssim内置函数可用，避免跑到一半才失败。
if exist("psnr", "file") ~= 2 || exist("ssim", "file") ~= 2
    error('rangeSFTMetrics:ToolboxMissing', ...
        ['缺少MATLAB内置psnr或ssim函数，' ...
        '需要Image Processing Toolbox。']);
end
end

function [dataset_root, parameter_key] = resolve_dataset_root( ...
        parent_directory, requested_key)
%RESOLVE_DATASET_ROOT 自动发现唯一参数键子目录并核验LQ/GT结构。
if ~isfolder(parent_directory)
    error('rangeSFTMetrics:DatasetParentMissing', ...
        '数据集父目录不存在：%s。', parent_directory);
end
entries = dir(parent_directory);
subdirectories = string({entries([entries.isdir]).name}).';
subdirectories = subdirectories( ...
    subdirectories ~= "." & subdirectories ~= "..");
if strlength(requested_key) > 0
    parameter_key = string(requested_key);
else
    if isempty(subdirectories)
        error('rangeSFTMetrics:DatasetEmpty', ...
            '数据集父目录下没有参数键子目录：%s。', parent_directory);
    elseif numel(subdirectories) ~= 1
        error('rangeSFTMetrics:DatasetAmbiguous', ...
            '存在%d个参数键子目录（%s），请显式指定PARAMETER_KEY。', ...
            numel(subdirectories), join(subdirectories, ", "));
    end
    parameter_key = subdirectories(1);
end
dataset_root = fullfile(parent_directory, parameter_key);
if ~isfolder(fullfile(dataset_root, "LQ")) || ...
        ~isfolder(fullfile(dataset_root, "GT"))
    error('rangeSFTMetrics:DatasetStructure', ...
        '数据集缺少LQ或GT目录：%s。', dataset_root);
end
end

function signature = load_dataset_signature(dataset_root)
%LOAD_DATASET_SIGNATURE 尽力读取生产协议签名；失败仅警告不中断。
signature = [];
metadata_path = fullfile(dataset_root, "dataset_metadata.mat");
if ~isfile(metadata_path)
    return;
end
try
    loaded = load(char(metadata_path), 'dataset_metadata');
    if isfield(loaded, 'dataset_metadata') && ...
            isfield(loaded.dataset_metadata, 'signature')
        signature = loaded.dataset_metadata.signature;
    end
catch load_error
    warning('rangeSFTMetrics:MetadataUnreadable', ...
        '无法读取数据集metadata（%s），跳过签名记录。', load_error.message);
end
end

function [names, scene_keys, rstart_ids, cstart_ids] = ...
        collect_sequences(dataset_root, n_frames)
%COLLECT_SEQUENCES 枚举并校验LQ/GT序列配对与九帧完整性。
lq_root = fullfile(dataset_root, "LQ");
gt_root = fullfile(dataset_root, "GT");
lq_names = sorted_folder_names(lq_root);
gt_names = sorted_folder_names(gt_root);

missing_in_gt = setdiff(lq_names, gt_names);
missing_in_lq = setdiff(gt_names, lq_names);
if ~isempty(missing_in_gt) || ~isempty(missing_in_lq)
    error('rangeSFTMetrics:SequenceUnpaired', ...
        'LQ/GT序列不配对：LQ独有[%s]，GT独有[%s]。', ...
        join(missing_in_gt, ", "), join(missing_in_lq, ", "));
end
names = lq_names;
if isempty(names)
    error('rangeSFTMetrics:SequencesEmpty', ...
        '数据集中没有任何序列：%s。', dataset_root);
end

sequence_count = numel(names);
scene_keys = strings(sequence_count, 1);
rstart_ids = nan(sequence_count, 1);
cstart_ids = nan(sequence_count, 1);
for seq_idx = 1:sequence_count
    % LQ与GT都必须恰好包含000~008.png，不完整直接报错
    if ~has_complete_frames(fullfile(lq_root, names(seq_idx)), n_frames) || ...
            ~has_complete_frames(fullfile(gt_root, names(seq_idx)), n_frames)
        error('rangeSFTMetrics:IncompleteSequence', ...
            '序列%s的LQ/GT帧不完整，请人工核查。', names(seq_idx));
    end
    token = regexp(char(names(seq_idx)), ...
        '^(\w+)_rstart_([0-9]+)_cstart_([0-9]+)$', 'tokens', 'once');
    if isempty(token)
        error('rangeSFTMetrics:SequenceName', ...
            '序列目录名无法解析场景键与起点：%s。', names(seq_idx));
    end
    scene_keys(seq_idx) = string(token{1});
    rstart_ids(seq_idx) = str2double(token{2});
    cstart_ids(seq_idx) = str2double(token{3});
end
end

function names = sorted_folder_names(root_directory)
%SORTED_FOLDER_NAMES 返回排序后的子目录名（N×1 string列向量）。
entries = dir(root_directory);
names = string({entries([entries.isdir]).name}).';
names = sort(names( ...
    names ~= "." & names ~= ".."));
names = names(:);
end

function yes = has_complete_frames(directory, frame_count)
%HAS_COMPLETE_FRAMES 要求目录恰好包含000.png至008.png。
files = dir(fullfile(directory, "*.png"));
actual = sort(lower(string({files.name})));
expected = sort(compose('%03d.png', 0:frame_count - 1));
yes = numel(actual) == frame_count && isequal(actual(:), expected(:));
end

function t = empty_results_table(n_frames)
%EMPTY_RESULTS_TABLE 构造0行的预分配有类型结果表，列结构与块表一致。
t = table(string.empty(0, 1), string.empty(0, 1), ...
    zeros(0, 1), zeros(0, 1), ...
    'VariableNames', ["SequenceName", "SceneKey", "RstartID", "CStartID"]);
for frame_idx = 0:n_frames - 1
    t.(sprintf('PSNR_Frame%03d', frame_idx)) = zeros(0, 1);
    t.(sprintf('SSIM_Frame%03d', frame_idx)) = zeros(0, 1);
end
end

function validate_checkpoint_results(results_table, all_names, scene_keys, ...
        rstart_ids, cstart_ids, n_frames)
%VALIDATE_CHECKPOINT_RESULTS 拒绝结构不完整或序列元数据错配的checkpoint。
if ~istable(results_table)
    error('rangeSFTMetrics:CheckpointTableType', ...
        'checkpoint中的results_table不是table，不能继续恢复。');
end

metric_variables = strings(1, 2 * n_frames);
for frame_idx = 0:n_frames - 1
    metric_variables(2 * frame_idx + 1) = ...
        string(sprintf('PSNR_Frame%03d', frame_idx));
    metric_variables(2 * frame_idx + 2) = ...
        string(sprintf('SSIM_Frame%03d', frame_idx));
end
required_variables = ["SequenceName", "SceneKey", "RstartID", ...
    "CStartID", metric_variables];
actual_variables = string(results_table.Properties.VariableNames);
missing_variables = required_variables(~ismember(required_variables, ...
    actual_variables));
if ~isempty(missing_variables)
    error('rangeSFTMetrics:CheckpointTableSchema', ...
        'checkpoint结果表缺少必要列：%s。', join(missing_variables, ", "));
end

if ~isstring(results_table.SequenceName) || ...
        ~isstring(results_table.SceneKey) || ...
        ~isnumeric(results_table.RstartID) || ...
        ~isnumeric(results_table.CStartID)
    error('rangeSFTMetrics:CheckpointColumnType', ...
        'checkpoint结果表的序列名称或元数据列类型不符合评估协议。');
end
for variable_name = metric_variables
    if ~isnumeric(results_table.(variable_name))
        error('rangeSFTMetrics:CheckpointColumnType', ...
            'checkpoint指标列%s不是数值类型。', variable_name);
    end
end

checkpoint_names = results_table.SequenceName(:);
if numel(unique(checkpoint_names)) ~= numel(checkpoint_names)
    error('rangeSFTMetrics:CheckpointDuplicateSequence', ...
        'checkpoint包含重复的SequenceName，不能继续恢复。');
end
[is_known_sequence, source_indices] = ismember(checkpoint_names, all_names);
if ~all(is_known_sequence)
    unknown_names = join(checkpoint_names(~is_known_sequence), ", ");
    error('rangeSFTMetrics:CheckpointUnknownSequence', ...
        'checkpoint包含当前数据集不存在的序列：%s。', unknown_names);
end

metadata_matches = ...
    isequal(results_table.SceneKey(:), scene_keys(source_indices)) && ...
    isequaln(results_table.RstartID(:), rstart_ids(source_indices)) && ...
    isequaln(results_table.CStartID(:), cstart_ids(source_indices));
if ~metadata_matches
    error('rangeSFTMetrics:CheckpointMetadataMismatch', ...
        ['checkpoint中的SceneKey、RstartID或CStartID与SequenceName不对应，' ...
        '请人工核查并移除错误checkpoint后重新评估。']);
end

metric_values = extract_frame_matrix(results_table, "PSNR_Frame", n_frames);
ssim_values = extract_frame_matrix(results_table, "SSIM_Frame", n_frames);
if any(~isfinite(metric_values), 'all') || ...
        any(~isfinite(ssim_values), 'all')
    error('rangeSFTMetrics:CheckpointNonFiniteMetric', ...
        'checkpoint包含非有限PSNR或SSIM值，不能将对应序列视为已完成。');
end
end

function rows = make_rows_table(chunk_names, chunk_scene_keys, ...
        chunk_rstart_ids, chunk_cstart_ids, psnr_values, ssim_values, n_frames)
%MAKE_ROWS_TABLE 由块计算结果构造与累计表同构的行块。
rows = table(chunk_names(:), chunk_scene_keys(:), ...
    chunk_rstart_ids(:), chunk_cstart_ids(:), ...
    'VariableNames', ["SequenceName", "SceneKey", "RstartID", "CStartID"]);
for frame_idx = 0:n_frames - 1
    % 逐帧列显式按列赋值，保证与累计表列类型一致
    rows.(sprintf('PSNR_Frame%03d', frame_idx)) = ...
        psnr_values(:, frame_idx + 1);
    rows.(sprintf('SSIM_Frame%03d', frame_idx)) = ...
        ssim_values(:, frame_idx + 1);
end
end

function values = extract_frame_matrix(results_table, prefix, n_frames)
%EXTRACT_FRAME_MATRIX 从table中提取N×9逐帧指标矩阵。
row_count = height(results_table);
values = zeros(row_count, n_frames);
for frame_idx = 0:n_frames - 1
    values(:, frame_idx + 1) = ...
        results_table.(sprintf('%s%03d', prefix, frame_idx));
end
end

function [use_parallel, workers_used] = setup_parallel_pool(worker_count)
%SETUP_PARALLEL_POOL 尝试使用并行池；许可证失败时降级串行。
use_parallel = false;
workers_used = 0;
if worker_count <= 0
    return;
end
try
    pool = gcp('nocreate');
    if isempty(pool)
        requested = min(worker_count, feature('numcores'));
        parpool(requested);
        pool = gcp('nocreate');
    end
    if ~isempty(pool)
        use_parallel = true;
        workers_used = pool.NumWorkers;
    end
catch pool_error
    warning('rangeSFTMetrics:ParallelUnavailable', ...
        '并行池不可用（%s），降级为串行运行。', pool_error.message);
end
end

function [psnr_values, ssim_values] = evaluate_sequence( ...
        dataset_root, sequence_name, n_frames)
%EVALUATE_SEQUENCE 逐帧读取LQ/GT并计算PSNR与SSIM（uint8按[0,255]）。
lq_directory = fullfile(dataset_root, "LQ", sequence_name);
gt_directory = fullfile(dataset_root, "GT", sequence_name);
psnr_values = nan(1, n_frames);
ssim_values = nan(1, n_frames);
for frame_idx = 1:n_frames
    frame_name = sprintf('%03d.png', frame_idx - 1);
    lq_image = imread(fullfile(lq_directory, frame_name));
    gt_image = imread(fullfile(gt_directory, frame_name));
    psnr_values(frame_idx) = double(psnr(lq_image, gt_image));
    ssim_values(frame_idx) = double(ssim(lq_image, gt_image));
end
end

function atomic_save_checkpoint(file_path, signature, results_table)
%ATOMIC_SAVE_CHECKPOINT 同目录临时文件原子提交checkpoint。
temporary = string(tempname(char(string(fileparts(file_path))))) + ".mat";
cleanup = onCleanup(@() delete_if_exists(temporary));
save(char(temporary), 'signature', 'results_table');
[ok, message] = movefile(temporary, file_path);
if ~ok
    error('rangeSFTMetrics:CheckpointSave', ...
        '保存checkpoint失败：%s。', message);
end
clear cleanup;
end

function delete_if_exists(file_path)
%DELETE_IF_EXISTS 删除本次未成功提交的临时checkpoint文件。
if isfile(file_path)
    delete(file_path);
end
end

function plot_metric_curve(frame_axis, mean_curve, std_curve, ...
        y_label, title_text, output_path)
%PLOT_METRIC_CURVE 绘制均值曲线及±1std阴影带并保存300dpi PNG。
figure_handle = figure('Color', 'w', 'Position', [100 100 900 600]);
hold on;
x = frame_axis(:).';                       % 显式1×N横坐标
mean_values = mean_curve(:).';             % 显式1×N纵坐标
std_values = std_curve(:).';
band_color = [0.30 0.50 0.80];
fill([x, fliplr(x)], ...
    [mean_values + std_values, fliplr(mean_values - std_values)], ...
    band_color, 'FaceAlpha', 0.15, 'EdgeColor', 'none');
plot(x, mean_values, 'o-', 'LineWidth', 2, 'Color', band_color, ...
    'MarkerFaceColor', band_color, 'MarkerSize', 6);
grid on;
box on;
xlabel('帧编号');
ylabel(y_label, 'Interpreter', 'none');
title(title_text, 'Interpreter', 'none');
xlim([frame_axis(1) - 0.5, frame_axis(end) + 0.5]);
xticks(frame_axis);
legend('±1 std', '均值', 'Location', 'best');
print(figure_handle, char(output_path), '-dpng', '-r300');
end

function ensure_directory(path)
%ENSURE_DIRECTORY 确保目标目录存在且可访问。
if isfolder(path)
    return;
end
[ok, message] = mkdir(path);
if ~ok
    error('rangeSFTMetrics:CreateDirectory', ...
        '无法创建目录%s：%s。', path, message);
end
end
