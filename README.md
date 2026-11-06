# songshancup-minimax

## 嵩山杯 MiniMax-H3 FL2VA 初赛

### 复现指令

统一输入图片：`sample_first_frame.jpg`
统一 FL2VA Prompt："A dog falls asleep"

1、将整个初赛文件夹上传到个人AFS的根目录。例：个人目录/初赛。
（复现完成后个人目录下会有初赛、fl2va-r10-submission两个文件夹。）
2、申请独占8卡的资源，执行如下命令。
```bash
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
- `初赛/离线依赖/`：仅保留 `恢复.sh`、`传输清单.json`、`文件清单.md`。其中大于 GitHub 单文件 100MB 限制的二进制依赖（`*.tar.gz`、`*.whl`、`FlashAttention.part*`）未入库，按 `初赛/.gitignore` 的说明经 Releases 分发。
- 提交前请核对 `初赛/离线依赖/传输清单.json` 与 `文件清单.md` 中的校验值。
