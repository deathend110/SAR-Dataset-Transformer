function setup_range_2dsft_paths(cfg)
%SETUP_RANGE_2DSFT_PATHS 添加普通函数目录，不使用MATLAB包目录。
addpath(cfg.repo_root);
for name = ["sarflow", "sampling", "sft", "sarproc"]
    addpath(fullfile(cfg.repo_root, name));
end
end
