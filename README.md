# songshancup-minimax

## 嵩山杯 MiniMax-H3 FL2VA 初赛
### 更改内容：
#### 仓库: InfiniCore
 链接: https://github.com/InfiniTensor/InfiniCore                   
 基线分支/提交: minimax-h3 / f32e2fbb2a9b2ca912b5711f4f3836c403196a74
 本队改动: InfiniCore.patch
 改动范围: 算子接口与运行时适配、海光 MHA 注册修复、九齿构建桥接、RoPE 生命周期修复
#### 仓库: InfiniLM
 链接: https://github.com/InfiniTensor/InfiniLM
 基线分支/提交: minimax_h3 / 65deb91f840ebaef752d028fad2f3217ce0950f4
 本队改动: InfiniLM.patch
 改动范围: MiniMax-H3 FL2A 接入、Qwen3-VL 条件编码、H3 Transformer、AdaLN 数值对齐、流/生命周期修复
#### 仓库: 九齿 NineToothed
 链接: https://github.com/InfiniTensor/ninetoothed
 基线分支/提交: master / f64a6de566aa1c7321aed92edb9285690cbf3c66
 本队改动: ninetoothed.patch
 改动范围: CUDA C 源码后端、gfx936 目标、sigmoid、二值 max/min、Triton 可选化
#### 仓库: ntops（九齿算子库
 链接: https://github.com/InfiniTensor/ntops
 基线分支/提交: master / 82cba6cf2200919b5d12c86adbea60cbfb516040
 本队改动: ntops.patch
 改动范围: median 算子的 Triton 可选导入修复
补丁清单位于 初赛/工程源码/附件/patches/，对应关系见 patch-manifest.json。
### 复现指令

统一输入图片：`sample_first_frame.jpg`
统一 FL2VA Prompt："A dog falls asleep"

1、将整个初赛文件夹上传到个人AFS的根目录。例：个人目录/初赛。
（复现完成后个人目录下会输出fl2va-r10-submission文件夹。）
2、下载 Release 上的 12 个离线包，放入 `个人目录/初赛/离线依赖`（资源名与文件名一致，无需改名）。
3、申请独占 8 卡的资源，打开终端执行如下命令。
```bash
# 进入工作目录
cd $IFAB_AFS_HOME/初赛
# 构建 InfiniCore 及配套绑定
bash run.sh build-core
# 构建 InfiniLM 及配套 SDK 绑定
bash run.sh build-lm
# 生成视频并评测
bash run.sh native
# 只比较已有视频
bash run.sh check
```
### 输出位置

| 内容                        | 路径                                                                           |
| ------------------------- | ---------------------------------------------------------------------------- |
| 生成的视频                     | `工程源码/结果/本次运行/result.mp4`                                                    |
| 评测结果                      | `工程源码/结果/本次运行/evaluation.json`、`evaluation.log`                              |
| 规格/配置/日志                  | 同目录 `specifications.json`、`config.json`、`generation.log`                     |
| 原始运行归档                    | `${IFAB_AFS_HOME}/fl2va-r10-submission/songshan/fl2va-output-<14位时间>.tar.gz` |
| `bash run.sh check` 的比较输出 | `工程源码/结果/本次评测/official-comparison.log`                                       |
| check 的调用身份与两视频指纹         | `工程源码/结果/本次评测/comparison-invocation.json`                                    |

`check` 使用 `结果/本次运行/result.mp4` 与随包参考视频，调用未修改的官方比较器；结果以文本形式写在 `official-comparison.log`，包含 Size、Length、Average SSIM。

### 仓库内容说明

- `初赛/工程源码/`：复现所需的源码、补丁、脚本与参考视频（体积较小，正常提交）。
- `初赛/离线依赖/`：仓库内只保留 `恢复.sh`、`传输清单.json`、`文件清单.md`、`release-assets.json`。12 个二进制依赖（合计 913 MB）因超出 GitHub 单文件 100 MB 硬限制未进入 Git 历史，全部随 Release 分发。
