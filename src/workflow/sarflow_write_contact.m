function sarflow_write_contact(cfg,role,key,scene,lq,gt)
%SARFLOW_WRITE_CONTACT 只由锁定候选和确认阶段输出代表图。
p=sarflow_paths(cfg);directory=fullfile(p.diagnostics,role,key);
if ~isfolder(directory),mkdir(directory);end
imwrite([reshape(lq,cfg.sequence.patch_size,[]);reshape(gt,cfg.sequence.patch_size,[])], ...
    fullfile(directory,scene+"_contact.png"));
end
