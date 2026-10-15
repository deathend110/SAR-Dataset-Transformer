# 参数筛选与数据集生产

## 输入与配置

`range_2dsft_config()`集中管理所有配置，默认阶段为`preflight`。

- `cfg.data_root`：外部原始回波目录，默认`G:\MATLAB-G\SAR Full PSF`；不复制进仓库。
- `cfg.parameter_file_60`：`inputs/parameters/FS60_params.mat`。
- `cfg.dataset_root`：最终数据集根目录，默认`dataset_range_2dsft/`。
- `cfg.results_root`：辅助结果根目录，默认`results_range_2dsft/`。

代码、数据集和辅助结果目录独立。为支持临时序列的目录提交，生成缓存和最终数据集需要位于同一卷。路径由公共路径函数统一生成。

根目录只保留配置及运行入口，阶段实现和公共算法位于普通`src/`子目录。路径初始化只添加明确的代码目录，不递归扫描数据。成像参数MAT由本机提供，Git不跟踪其二进制内容；参考参数和当前参数设置快照位于`inputs/reference/`，不会代替搜索和确认。

## 执行阶段

```matlab
cfg = range_2dsft_config();
cfg.stage = "preflight";
run_range_2dsft_workflow(cfg);
```

| stage       | 工作                 | 前置条件        |
| ----------- | ------------------ | ----------- |
| `preflight` | 文件头、协议、样本清单、候选网格预检 | 原始回波和成像参数可用 |
| `search`    | 粗搜索、局部细化和参数锁定      | 自动预检        |
| `confirm`   | 独立样本确认，不重新选优       | 搜索完整完成      |
| `stats`     | 正式场景JointHL和GT统计   | 确认完成        |
| `generate`  | 所有锁定参数组的LQ/GT生成    | 正式统计完成      |
| `evaluate`  | 最终PNG指标和曲线         | 生成完成        |
| `all`       | 顺序执行全部阶段           | 自动预检        |

统一入口负责阶段前置检查。根目录各`run_range_2dsft_*`阶段函数也可显式调用；其中统计和生成函数需要传入完整参数，评估函数需要参数键，它们不伪造搜索或确认完成状态。

```matlab
% 以下调用将开始实际参数搜索，可能耗时很长。
cfg.stage = "search";
run_range_2dsft_workflow(cfg);
```

## 筛选协议

默认倍率组为`[4,2; 2.5,1.5; 3.25,1.75]`。H/L只改变距离上采样倍率，STR、两方向阈值频率及初相位共享；初相位固定0。

每场景数值排序轨迹后分层抽取7条，第3、5条确认，其余5条搜索，每轨迹一条九帧序列；7场景共35条搜索、14条确认。清单固定保存。若依据确认结果修改搜索方案，应排除已使用的确认轨迹并重新建立独立样本；`cfg.search.exclude_files`接受需排除的轨迹完整路径。

粗网格为STR=`-10:2:10`、两频率=`0:0.2:4`，由H/L共同Nyquist上限及0.98安全余量裁剪，默认594个候选。每组粗选最优点附近以STR偏移`-2:1:2`、频率偏移`-0.2:0.05:0.2`细化，并排除重复候选。所有粗细候选完成后才锁定。

每个候选使用搜索样本拟合场景级JointHL统计：能量对齐后的纯H及纯L等像素权重汇总，使用精确midpoint分位数；GT按场景独立统计并共享。确认阶段使用搜索统计，不重新拟合。正式生产按每轨迹均匀10条序列重新拟合，不能复用搜索统计作为正式统计。

指标按最终PNG的uint8口径计算：600 ROI归一化、512裁剪、量化后计算PSNR/SSIM。场景等权，以平均SSIM、L区SSIM、最差帧SSIM、PSNR依次排序，最后按参数键打破并列。亮点、梯度、边界和重叠诊断在[0,1]上计算，未设置硬门槛。确认结果只报告差异，不参与重新选优；这些样本角色不规定恢复模型的训练/测试划分。

## 文件归属

```text
dataset_range_2dsft/<参数键>/
    LQ/<序列名>/000.png … 008.png
    GT/<序列名>/000.png … 008.png
    dataset_metadata.mat

results_range_2dsft/
    protocol/        配置、清单、预检
    search/          排名、锁定参数CSV/MAT
    confirmation/    独立确认表格
    normalization/   正式场景统计MAT
    evaluation/<键>/ 最终指标明细与曲线
    diagnostics/     联系图和结构诊断图
    checkpoints/     搜索、统计、生成、评估进度
    cache/           GT缓存、像素chunk、未提交PNG
    migration/       一次性文件映射、回退副本及迁移记录
```

不使用RunID，不为重复执行创建版本副本。同一配置完整结果复用，中断续算；签名使用`isequaln`比较，配置不一致则报错。正式统计成功提交后只清理相应可再生像素chunk。

临时PNG在生成缓存写完整，保存提交断点后再移入最终目录；若在GT/LQ提交之间中断，可依断点继续提交。没有合法断点的残缺序列报错，不自动删除。

数据集metadata保存实际归一化快照；路径或来源记录改变时仍需确认生产参数、输入清单和归一化口径一致，不能仅凭相同参数键复用PNG。评估checkpoint另存，不混入最终指标报告。

## 检查与小型验证

```matlab
results = runtests("tests/TestSarWorkflow.m");
assertSuccess(results);
```

轻量测试不执行完整搜索或真实数据生产。`range_2dsft_smoke_config(fixture_root, parameter_file)`提供单场景、两个粗候选的小型闭环配置，数据和辅助结果分别写入fixture目录下两个独立子目录；默认仍只预检。完整实验由用户明确启动。

一次性目录迁移使用`migrate_range_2dsft_layout("preview")`读取精确映射，`"apply"`更新小型文件引用，`"rollback"`恢复映射涉及的文件。它不处理PNG内容；迁移原始副本和回退清单保存在辅助结果目录。
