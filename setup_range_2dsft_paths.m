function directory_guard = setup_range_2dsft_paths(cfg)
%SETUP_RANGE_2DSFT_PATHS 添加普通源码目录；入口持有guard以隔离当前目录。
% MATLAB当前目录优先于addpath。持有返回的onCleanup可在正常结束或报错后
% 恢复调用者目录，避免旧工程的同名函数进入搜索、统计和生成流程。
if nargout>0
    previous_directory=pwd;
    cd(cfg.repo_root);
    directory_guard=onCleanup(@()cd(previous_directory));
end
addpath(cfg.repo_root);
for name=["workflow","sampling","sft","sarproc","utils","compat"]
    addpath(fullfile(cfg.repo_root,"src",name));
end
end
