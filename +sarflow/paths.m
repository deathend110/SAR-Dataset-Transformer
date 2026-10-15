function p = paths(cfg)
%PATHS 新运行隔离全部输出；旧脚本仍访问原目录。
p.root = fullfile(cfg.output_root, cfg.run_id);
p.search = fullfile(p.root, "search");
p.stats = fullfile(p.root, "stats");
p.dataset = fullfile(p.root, "dataset");
p.evaluation = fullfile(p.root, "evaluation");
if cfg.legacy
    p.stats = fullfile(cfg.repo_root, "results_range_2dsft_scene_percentiles");
    p.dataset = fullfile(cfg.repo_root, "dataset_range_2dsft");
    p.evaluation = fullfile(cfg.repo_root, "results_range_2dsft_psnr_ssim");
end
p.lock = fullfile(p.search, "locked_parameters.mat");
end
