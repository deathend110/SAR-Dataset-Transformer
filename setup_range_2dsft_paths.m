function setup_range_2dsft_paths(cfg)
%SETUP_RANGE_2DSFT_PATHS 仅添加明确的普通代码目录，避免扫描数据与结果。
addpath(cfg.repo_root);
for name=["workflow","sampling","sft","sarproc","utils","compat"]
    addpath(fullfile(cfg.repo_root,"src",name));
end
end
