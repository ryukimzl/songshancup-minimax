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
- `初赛/离线依赖/`：仓库内只保留 `恢复.sh`、`下载依赖.sh`、`传输清单.json`、`文件清单.md`、`release-assets.json`。12 个二进制依赖（合计 913 MB）因超出 GitHub 单文件 100 MB 硬限制未进入 Git 历史，全部随 Release 分发。
- 提交前请核对 `初赛/离线依赖/传输清单.json` 与 `文件清单.md` 中的校验值。

### 获取离线依赖（首次使用必做）

12 个依赖二进制挂在 Release [v0-r10-deps](https://github.com/ryukimzl/songshancup-minimax/releases/tag/v0-r10-deps) 上，执行下面一条命令即可下载、改回原始文件名并逐个校验 SHA256：

```bash
cd 初赛/离线依赖
bash 下载依赖.sh                 # 直连
# 需要代理时：
https_proxy=http://127.0.0.1:7890 bash 下载依赖.sh
```

校验通过后目录中会出现 `构建工具_Xmake.tar.gz`、`Python基础依赖.tar.gz`、`Python模型依赖.tar.gz`、`视频评测依赖.tar.gz`、`Triton依赖.whl`、`FlashAttention.part01` 至 `part07`，与原提交包一致。GitHub 对 Release 资源名有 ASCII 限制，因此资源名（如 `flash_attention.whl.part00`）与原始中文文件名不同，映射关系见 `初赛/离线依赖/release-assets.json`。
