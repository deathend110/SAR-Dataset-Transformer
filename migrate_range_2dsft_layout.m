function report = migrate_range_2dsft_layout(mode)
%MIGRATE_RANGE_2DSFT_LAYOUT 一次性目录迁移；preview只列清单，apply更新已复制文件引用。
if nargin==0,mode="preview";end
cfg=range_2dsft_config();setup_range_2dsft_paths(cfg);
report=sarflow_migrate_layout(cfg,string(mode));
end
