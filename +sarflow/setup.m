function setup(cfg)
%SETUP 只添加本仓库公共函数，不依赖验证仓库。
addpath(cfg.repo_root);
for name = ["sampling", "sft", "sarproc"]
    addpath(fullfile(cfg.repo_root, name));
end
end
