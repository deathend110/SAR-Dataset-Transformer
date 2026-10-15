function output_root = run_range_2dsft_stats(cfg, PARAMETERS)
%RUN_RANGE_2DSFT_STATS 可调用的正式场景统计入口，不清空调用者工作区。
sarflow.setup(cfg);
paths = sarflow.paths(cfg);
OUTPUT_ROOT = paths.stats;
WORK_ROOT = fullfile(OUTPUT_ROOT, "_work");
if cfg.legacy && strlength(cfg.stats.work_root)>0, WORK_ROOT = cfg.stats.work_root; end
BLOCKS_PER_FILE = cfg.stats.blocks_per_file;
LOW_PERCENTILE = cfg.low_percentile;
HIGH_PERCENTILE = cfg.high_percentile;
ROI_SIZE = cfg.sequence.roi_size;
ENERGY_BUFFER = cfg.energy_buffer;
MAX_IN_MEMORY_PERCENTILE_GB = cfg.stats.memory_gb;
ENABLE_IN_MEMORY_PERCENTILE = cfg.stats.in_memory;
S60 = load(cfg.parameter_file_60);
% protocol记录所有会影响统计结果的公共规则；manifest固定数据来源。
protocol = sarflow.statistics("build_protocol", cfg, S60, BLOCKS_PER_FILE, ...
    LOW_PERCENTILE, HIGH_PERCENTILE, ROI_SIZE, ENERGY_BUFFER);
if ~cfg.legacy
    protocol.workflow = cfg.provenance;
end
sarflow.statistics("validate_parameters", PARAMETERS, cfg, S60, protocol);
manifest = sarflow.statistics("build_scene_manifest", cfg, BLOCKS_PER_FILE);
parameter_keys = sarflow.statistics("build_parameter_keys", PARAMETERS, protocol);

fprintf('场景级分位数清单：%d个场景，%d个文件，%d条序列。\n', ...
    numel(unique(manifest.Scene)), ...
    numel(unique(manifest.FilePath)), height(manifest));
for parameter_idx = 1:height(PARAMETERS)
    fprintf('  参数%d：%s\n', parameter_idx, parameter_keys(parameter_idx));
end
sarflow.statistics("print_scene_counts", manifest);

sarflow.statistics("ensure_directory", OUTPUT_ROOT);
sarflow.statistics("ensure_directory", WORK_ROOT);
scenes = unique(string(manifest.Scene), 'stable');

%% ========================== 场景与参数循环 ===============================
for scene_idx = 1:numel(scenes)
    scene = scenes(scene_idx); % 当前场景全名，例如SAR_Dataset_port
    scene_manifest = manifest(string(manifest.Scene) == scene, :);
    scene_key = string(scene_manifest.SceneKey(1)); % 稳定、可读的MAT文件名
    output_path = fullfile(OUTPUT_ROOT, scene_key + ".mat");
    % header用于确认已有MAT与本次场景、清单和统计协议完全一致。
    header = struct( ...
        "schema_version", "range_2dsft_scene_percentiles_v2", ...
        "scene_name", scene, ...
        "scene_key", scene_key, ...
        "protocol", protocol, ...
        "source_manifest", scene_manifest);
    gt_stats = sarflow.statistics("load_existing_gt", output_path, header); % GT与SFT参数无关，场景内共享

    fprintf('\n[%d/%d] 场景%s：%d个文件，%d条序列。\n', ...
        scene_idx, numel(scenes), scene, ...
        numel(unique(scene_manifest.FilePath)), height(scene_manifest));

    for parameter_idx = 1:height(PARAMETERS)
        parameter_row = PARAMETERS(parameter_idx, :); % 当前倍率和SFT参数行
        parameters = sarflow.statistics("parameter_struct", parameter_row);
        parameter_key = parameter_keys(parameter_idx); % MAT条目的唯一可读键
        pair = make_range_sft_pair(parameters);
        % 有效倍率由round(q*N)后的真实尺寸决定，并用于Nyquist检查。
        [grid_h, grid_l] = resolve_pair_grids( ...
            pair, cfg.sequence, S60, cfg.nyquist_margin);
        need_gt = isempty(fieldnames(gt_stats)); % 仅场景首个参数需要同步计算GT
        work_directory = fullfile(WORK_ROOT, scene_key, parameter_key);

        fprintf('  [%d/%d] %s\n', ...
            parameter_idx, height(PARAMETERS), parameter_key);
        if sarflow.statistics("scene_entry_exists", output_path, parameter_key)
            sarflow.statistics("remove_completed_work_directory", work_directory, WORK_ROOT);
            fprintf('    该参数已有完整统计，跳过。\n');
            continue;
        end
        carrier_h = build_2dsft_carrier( ...
            grid_h, pair.H.threshold, S60);
        carrier_l = build_2dsft_carrier( ...
            grid_l, pair.L.threshold, S60);
        result = sarflow.statistics("process_scene_parameter",  ...
            cfg, S60, scene_manifest, pair, parameters, protocol, ...
            work_directory, need_gt, carrier_h, carrier_l, ...
            MAX_IN_MEMORY_PERCENTILE_GB, ENABLE_IN_MEMORY_PERCENTILE);
        if need_gt
            gt_stats = result.gt_stats;
        end

        % 一个entry对应一套完整Range+2D-SFT参数及其JointHL输入分位数。
        entry = struct( ...
            "parameter_key", parameter_key, ...
            "parameters", parameters, ...
            "effective_sampling", struct("H", grid_h, "L", grid_l), ...
            "input_stats", result.input_stats, ...
            "audit", result.audit, ...
            "created_at", "", ...
            "updated_at", "");
        sarflow.statistics("upsert_scene_stats",  ...
            output_path, header, gt_stats, entry);
        sarflow.statistics("remove_completed_work_directory", work_directory, WORK_ROOT);
        fprintf('    已更新%s。\n', output_path);
    end
end

fprintf('\n全部场景和参数统计完成：%s\n', OUTPUT_ROOT);

%% ============================== 本地函数 =================================
output_root = OUTPUT_ROOT;
end
