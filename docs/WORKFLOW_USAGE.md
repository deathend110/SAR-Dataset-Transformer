# 参数筛选与数据集生产

## 输入与配置

`range_2dsft_config()`集中管理所有配置，默认阶段为`preflight`。

- `cfg.data_root`：外部原始回波目录，默认`G:\MATLAB-G\SAR Full PSF`；不复制进仓库。
- `cfg.parameter_file_60`：`inputs/parameters/FS60_params.mat`。
- `cfg.dataset_root`：最终数据集根目录，默认`dataset_range_2dsft/`。
- `cfg.results_root`：辅助结果根目录，默认`results_range_2dsft/`。

代码、数据集和辅助结果目录独立。为支持临时序列的目录提交，生成缓存和最终数据集需要位于同一卷。路径由公共路径函数统一生成。

根目录只保留配置及运行入口，阶段实现和公共算法位于普通`src/`子目录。路径初始化只添加明确的代码目录，不递归扫描数据。成像参数MAT由本机提供，Git不跟踪其二进制内容；参考参数表位于`inputs/reference/`，不会代替搜索和确认。

## 在编辑器中启动

打开根目录的 `start_range_2dsft.m`，直接点击MATLAB编辑器的“运行”。所有常用设置集中在脚本参数区：倍率组、执行阶段、输入输出目录、场景、搜索网格、统计内存及评估并行数。

该脚本的参数区覆盖集中配置中的对应默认值，默认仅处理新增的 `QH=3、QL=2`，阶段为 `all`，会执行完整搜索及生产。只想检查配置时，将 `cfg.stage` 改为 `"preflight"`。中断后保持参数不变，再次点击“运行”即可按断点恢复。脚本执行完后，`cfg`和`workflow_result`保留在工作区，便于查看。

### 选择混合倍率或固定 Q 对照

在同一个启动脚本顶部修改模式，不需要命令行：

```matlab
% H-L-H混合倍率，默认保持原有3/2实验。
cfg.sampling_mode = "hlh";
cfg.search.hl_pairs = [3,2];
```

```matlab
% 固定Q对照：依次搜索、确认、统计、生成及评估三个Q。
cfg.sampling_mode = "fixed_q";
cfg.search.fixed_q_values = [2,2.5,3];
cfg.stage = "all";
```

每次启动只运行所选模式。固定模式不读取`hl_pairs`，混合模式不读取`fixed_q_values`。工厂配置仍默认`preflight`；编辑器启动脚本默认`all`，点击运行会开始实际实验。

固定模式仍然只沿距离维上采样，使用二维SFT阈值。每条连续块只生成一条指定Q的RC分支，九帧均来自该分支，完全跳过H/L能量对齐和空间混合。小数倍率按`round(Q*N)`构建实际采样网格。

每个Q独立搜索一套跨场景和序列共享的STR、fr/Br、fa/Ba，初相位固定0；“全局最优”仅指搜索网格及当前样本上的最优，不保证网格外的数学最优。阈值幅度仍按当前回波块估计尺度。

固定模式采用与混合模式相同的轨迹和序列选择规则；来源及抽样配置相同时，两种模式样本相同。每个候选用搜索样本的单分支九帧ROI拟合场景分位数，每帧只计一次，不使用JointHL。GT在场景内跨候选、跨Q共享。确认只读取搜索拟合统计；正式统计仍按每轨迹10条序列重新计算。

固定模式场景等权，按平均SSIM、最差帧SSIM、平均PSNR、稳定参数键排序。L区SSIM和H/L边界指标为`NaN`（不适用），不参与排序；亮点、梯度、重叠诊断和联系图继续输出。统一入口自动读取该模式的锁定MAT，将最优参数交给统计和生产，无需手动复制阈值。

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
| `stats`     | 正式场景输入和GT统计   | 确认完成        |
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
```

混合模式保持上面的辅助目录。固定模式的`protocol`、`search`、`confirmation`、`normalization`、`diagnostics`、`checkpoints`、`cache`各自增加`fixed_q/`子目录；评估仍保存到`evaluation/<参数键>/`。

固定数据集仍直接位于`dataset_range_2dsft/<参数键>/`，例如`range_2d_sft_q2_s0_fr0p2_fa0p2_phi0_lp0p99_hp99p9_roi600`。小数Q编码为`q2p5`；不包含无效的H/L边界缓冲字段。metadata记录固定模式、实际Q、单分支统计及各阶段来源。已有混合数据集和其参数键保持不变。

不使用RunID，不为重复执行创建版本副本。同一配置完整结果复用，中断续算；签名使用`isequaln`比较，配置不一致则报错。正式统计成功提交后只清理相应可再生像素chunk。

临时PNG在生成缓存写完整，保存提交断点后再移入最终目录；若在GT/LQ提交之间中断，可依断点继续提交。没有合法断点的残缺序列报错，不自动删除。

数据集metadata保存实际归一化快照；路径或来源记录改变时仍需确认生产参数、输入清单和归一化口径一致，不能仅凭相同参数键复用PNG。评估checkpoint另存，不混入最终指标报告。

## 检查与小型验证

```matlab
results = runtests("tests");
assertSuccess(results);
```

轻量测试不执行完整搜索或真实场景生产。`TestSarFixedQ`包含临时合成单场景、两条轨迹、单候选的真实成像闭环，并覆盖确认统计隔离、候选汇总中断恢复及完整PNG复用；测试结束清理自身临时目录。`range_2dsft_smoke_config(fixture_root, parameter_file)`提供单场景、两个粗候选的小型闭环配置，数据和辅助结果分别写入fixture目录下两个独立子目录；默认仍只预检。完整实验由用户明确启动。
