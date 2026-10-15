function cfg = range_2dsft_config()
%RANGE_2DSFT_CONFIG 集中配置；默认仅预检，不启动成像或长实验。
cfg = struct();
cfg.repo_root = string(fileparts(mfilename('fullpath')));
cfg.version = "range_2dsft_workflow_v1";
cfg.stage = "preflight";
cfg.dataset_root = fullfile(cfg.repo_root, "dataset_range_2dsft");
cfg.results_root = fullfile(cfg.repo_root, "results_range_2dsft");
cfg.data_root = "G:\MATLAB-G\SAR Full PSF";
cfg.parameter_file_60 = fullfile(cfg.repo_root, "inputs", "parameters", "FS60_params.mat");
cfg.dataset_names = ["SAR_Dataset_Bangkok_1", "SAR_Dataset_city1_histeq", ...
    "SAR_Dataset_city2_histeq", "SAR_Dataset_SAR_figure", ...
    "SAR_Dataset_filed", "SAR_Dataset_port", "SAR_Dataset_suburb"];
cfg.sequence = struct("n_frames", 9, "step", 128, ...
    "signal_height", 1200, "signal_width", 1200, ...
    "patch_size", 512, "roi_size", 600, "valid_margin", 344, ...
    "logic_length", 1536, "block_width", 2224);
cfg.nyquist_margin = 0.98;
cfg.energy_buffer = 64;
cfg.low_percentile = 0.99;
cfg.high_percentile = 99.9;
cfg.search = struct("hl_pairs", [4,2; 2.5,1.5; 3.25,1.75], ...
    "STR_grid", -10:2:10, "fr_grid", 0:0.2:4, "fa_grid", 0:0.2:4, ...
    "fine_STR_offsets", -2:1:2, "fine_frequency_offsets", -0.2:0.05:0.2, ...
    "phi0", 0, "search_per_scene", 5, "confirm_per_scene", 2);
% 根据确认结果调整方案后，可排除旧运行轨迹，重新建立独立确认样本。
cfg.search.exclude_files = strings(0,1);
cfg.stats = struct("blocks_per_file", 10, "memory_gb", 8, "in_memory", true);
cfg.generate = struct("stride_frames", 3, "gt_cache_frames", 32);
cfg.evaluate = struct("workers", 0, "chunk_size", 256);
cfg.provenance = struct();
end
