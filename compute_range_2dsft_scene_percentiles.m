clear; clc;close all;

%% ========================================================================
% Range+2D-SFT 场景级分位数统计
%
% 本脚本只统计未经归一化的幅度图分位数，不生成PNG或评价指标。
% 每个rstart文件均匀抽取10条H-L-H序列；同一参数下，H分支先按
% RC边界能量缩放，再与L分支的纯分支成像结果等权汇总为JointHL。
%
% 直接运行本脚本即开始正式统计。长时间任务按“场景+参数+序列”
% 自动保存checkpoint，中断后使用相同配置重新运行即可继续。
%% ========================================================================

%% ============================== 参数区 ==================================
% 每一行是一套生产参数；H/L严格共享STR、fr、fa和phi0，仅q不同。
PARAMETERS = table( ...
    [4; 2.5], ...          % QHigh
    [2; 1.5], ...          % QLow
    [-1; 1], ...           % STRdB
    [1.3; 0.9], ...        % FrOverBr
    [0.5; 0.5], ...        % FaOverBa
    [0; 0], ...            % Phi0，单位rad
    'VariableNames', [ ...
    "QHigh", "QLow", "STRdB", "FrOverBr", "FaOverBa", "Phi0"]);

BLOCKS_PER_FILE = 10;     % 每条rstart轨迹均匀抽取的连续序列数量
LOW_PERCENTILE = 0.99;   % Robust min-max下限：0.99百分位
HIGH_PERCENTILE = 99.9;  % Robust min-max上限：99.9百分位
ROI_SIZE = 600;          % 分位数必须在600×600原始幅度ROI上统计
ENERGY_BUFFER = 64;      % 每个H/L边界两侧用于估计功率的RC列数
WORK_ROOT_OVERRIDE = "C:\TEMP"; % 为空时使用正式统计目录下的_work。
MAX_IN_MEMORY_PERCENTILE_GB = 8; % 精确memory backend的最大single数据量
ENABLE_IN_MEMORY_PERCENTILE = true; % 数据量不超过上限时使用精确memory backend

cfg = range_2dsft_config("legacy");
cfg.stats.blocks_per_file = BLOCKS_PER_FILE;
cfg.stats.work_root = WORK_ROOT_OVERRIDE;
cfg.low_percentile = LOW_PERCENTILE;
cfg.high_percentile = HIGH_PERCENTILE;
cfg.energy_buffer = ENERGY_BUFFER;
cfg.sequence.roi_size = ROI_SIZE;
cfg.stats.memory_gb = MAX_IN_MEMORY_PERCENTILE_GB;
cfg.stats.in_memory = ENABLE_IN_MEMORY_PERCENTILE;
run_range_2dsft_stats(cfg, PARAMETERS);
