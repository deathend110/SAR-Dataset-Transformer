%% Range+2D-SFT 数据集完整流程启动脚本
% 在MATLAB编辑器中打开本文件，修改下面的参数区后直接点击“运行”。
% 默认处理QH=3、QL=2，并执行参数搜索到数据集评估的完整流程。
% 仅查看配置和样本清单时，将cfg.stage改为"preflight"。
clc;

% 以脚本所在目录定位工程，支持从其他MATLAB当前文件夹启动。
script_directory = string(fileparts(mfilename('fullpath')));
addpath(script_directory);
cfg = range_2dsft_config();

%% ============================= 参数区 ==================================
% all：预检→搜索→独立确认→正式统计→数据生成→全量评估。
% 也可选preflight、search、confirm、stats、generate或evaluate。
cfg.stage = "all";

% 每行是一组[QH, QL]；本次只处理新增的3/2，不重新搜索其他倍率组。
% 多组示例：[4,2; 2.5,1.5; 3.25,1.75; 3,2]。
cfg.search.hl_pairs = [3, 2];

% 原始回波、最终数据集和辅助结果分开存放。
cfg.data_root = "G:\MATLAB-G\SAR Full PSF";
cfg.parameter_file_60 = fullfile(script_directory, "inputs", "parameters", "FS60_params.mat");
cfg.dataset_root = fullfile(script_directory, "dataset_range_2dsft");
cfg.results_root = fullfile(script_directory, "results_range_2dsft");

% 使用的场景；删除某一项即可不处理该场景。
cfg.dataset_names = [ ...
    "SAR_Dataset_Bangkok_1", "SAR_Dataset_city1_histeq", ...
    "SAR_Dataset_city2_histeq", "SAR_Dataset_SAR_figure", ...
    "SAR_Dataset_filed", "SAR_Dataset_port", "SAR_Dataset_suburb"];

% 搜索H/L共享的STR、距离和方位阈值频率；初相位固定为0。
cfg.search.STR_grid = -10:2:10;
cfg.search.fr_grid = 0:0.2:4;
cfg.search.fa_grid = 0:0.2:4;
cfg.search.fine_STR_offsets = -2:1:2;
cfg.search.fine_frequency_offsets = -0.2:0.05:0.2;
cfg.search.search_per_scene = 5;
cfg.search.confirm_per_scene = 2;

% 正式归一化统计的抽样量、精确分位数内存上限及评估并行设置。
cfg.stats.blocks_per_file = 10;
cfg.stats.memory_gb = 8;
cfg.stats.in_memory = true;
cfg.evaluate.workers = 0; % 0为串行；正整数为评估阶段的并行worker数。
cfg.evaluate.chunk_size = 256;

%% ============================ 启动流程 =================================
fprintf('执行阶段：%s\n', cfg.stage);
disp(array2table(cfg.search.hl_pairs, 'VariableNames', {'QH', 'QL'}));
fprintf('最终数据集：%s\n', cfg.dataset_root);
fprintf('辅助结果：%s\n', cfg.results_root);

% 统一入口自动读取锁定参数，交给后续统计和成像阶段；不手填最优阈值。
workflow_timer = tic;
workflow_result = run_range_2dsft_workflow(cfg);
fprintf('所选流程执行完成，用时 %.1f 分钟。\n', toc(workflow_timer) / 60);
