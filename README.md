# SAR Dataset Transformer

将外部复数SAR回波转换为九帧H-L-H配对数据集，支持参数筛选、独立确认、正式场景归一化统计、PNG生成及全量指标评价。

## 目录

- 根目录：配置和公共运行入口。
- `src/`：普通MATLAB函数目录；`tests/`：轻量测试；`docs/`：使用说明。
- `inputs/`：成像参数和参考参数设置。
- `dataset_range_2dsft/<完整参数键>/LQ、GT`：最终九帧序列及数据集metadata。
- `results_range_2dsft/`：报告、正式统计、断点、缓存及诊断图，按用途分目录。

## 开始使用

在MATLAB编辑器中打开 `start_range_2dsft.m`，修改顶部参数区，然后点击“运行”，无需命令行操作。脚本默认对 `QH=3、QL=2` 执行完整流程；只需预检时，将脚本中的 `cfg.stage` 改为 `"preflight"`。

启动脚本调用统一工作流，不包含另一套处理逻辑。详细阶段用法与恢复说明见[工作流说明](docs/WORKFLOW_USAGE.md)。
