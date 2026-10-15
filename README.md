# SAR Dataset Transformer

将外部复数SAR回波转换为九帧H-L-H配对数据集，支持参数筛选、独立确认、正式场景归一化统计、PNG生成及全量指标评价。

## 目录

- 根目录：配置和公共运行入口。
- `src/`：普通MATLAB函数目录；`tests/`：轻量测试；`docs/`：使用说明。
- `inputs/`：成像参数和参考参数设置。
- `dataset_range_2dsft/<完整参数键>/LQ、GT`：最终九帧序列及数据集metadata。
- `results_range_2dsft/`：报告、正式统计、断点、缓存及诊断图，按用途分目录。

## 开始使用

```matlab
cfg = range_2dsft_config();
run_range_2dsft_workflow(cfg); % 默认仅预检
```

详细阶段用法与恢复说明见[工作流说明](docs/WORKFLOW_USAGE.md)。完整搜索和生产须显式选择对应阶段，不会由预检自动启动。
