function cfg = range_2dsft_smoke_config(fixture_root, parameter_file)
%RANGE_2DSFT_SMOKE_CONFIG 单场景、单倍率、两个粗候选的显式轻量闭环配置。
% fixture_root应为独立的小型数据目录，包含SmokeScene/rstart 1.mat等7条轨迹。
% 回波仍需满足正式1200x2224协议；不会自动启动或生成这些数据。
cfg=range_2dsft_config();
cfg.run_id="smoke_v1";
cfg.data_root=string(fixture_root);
cfg.parameter_file_60=string(parameter_file);
cfg.dataset_names="SmokeScene";
cfg.search.hl_pairs=[1.25,1];
cfg.search.STR_grid=[0,2];cfg.search.fr_grid=0;cfg.search.fa_grid=0;
cfg.search.fine_STR_offsets=0;cfg.search.fine_frequency_offsets=0;
cfg.stats.blocks_per_file=1;
cfg.stage="preflight"; % 用户显式选择all后才执行闭环。
end
