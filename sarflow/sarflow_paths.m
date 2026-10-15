function p = sarflow_paths(cfg)
%PATHS 数据集统一使用原目录；工作流状态只保留当前配置的一份。
p.root = cfg.output_root;
p.search = fullfile(p.root, "search");
p.stats = fullfile(p.root, "stats");
p.dataset = fullfile(cfg.repo_root, "dataset_range_2dsft");
p.evaluation = fullfile(p.root, "evaluation");
if cfg.legacy
    p.stats = fullfile(cfg.repo_root, "results_range_2dsft_scene_percentiles");
    p.evaluation = fullfile(cfg.repo_root, "results_range_2dsft_psnr_ssim");
end
p.lock = fullfile(p.search, "locked_parameters.mat");
end
