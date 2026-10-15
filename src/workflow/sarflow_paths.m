function p = sarflow_paths(cfg)
%SARFLOW_PATHS 最终数据、正式报告、断点与可再生缓存分别管理。
p.root=cfg.results_root;
p.dataset=cfg.dataset_root;
p.protocol=fullfile(p.root,"protocol");
p.search=fullfile(p.root,"search");
p.confirmation=fullfile(p.root,"confirmation");
p.stats=fullfile(p.root,"normalization");
p.evaluation=fullfile(p.root,"evaluation");
p.diagnostics=fullfile(p.root,"diagnostics");
p.checkpoints=fullfile(p.root,"checkpoints");
p.cache=fullfile(p.root,"cache");
if sarflow_is_fixed(cfg)
    for name=["protocol","search","confirmation","stats","diagnostics","checkpoints","cache"]
        p.(name)=fullfile(p.(name),"fixed_q");
    end
end
p.lock=fullfile(p.search,"locked_parameters.mat");
end
