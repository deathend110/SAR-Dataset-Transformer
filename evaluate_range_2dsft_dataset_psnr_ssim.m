clear; clc; close all;
% 兼容旧数据集的评估入口；统一工作流会自动逐组传入锁定参数键。
PARAMETER_KEY = "range_2d_sft_qh4_ql2_sm1_fr1p3_fa0p5_phi0_lp0p99_hp99p9_roi600_eb64";       % 留空自动发现唯一参数键子目录；多个时必须显式指定
cfg = range_2dsft_config("legacy");
cfg.evaluate.workers = 8;
run_range_2dsft_evaluate(cfg, PARAMETER_KEY);
