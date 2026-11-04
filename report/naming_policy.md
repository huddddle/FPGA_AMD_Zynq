# 文件命名与工具兼容

仓库内目录和文件名使用小写英文字母、数字、下划线与连字符，扩展名分隔点及 `.gitignore`、`.gitattributes` 的前导点保留。首页采用 `readme.md`，许可证采用 `license`，交接文件采用 `handoff.md`。

原生工具名称按以下方式处理：

| 仓库名称 | 使用方式 |
| --- | --- |
| `src/ps_software/*/native/cmakelists.txt` | PS 构建脚本在仓库外工作副本中恢复 `CMakeLists.txt`；CMake 从工作副本运行 |
| `src/ps_software/loopback/makefile` | GNU make 支持小写 `makefile`；内核模块构建时按构建说明复制为外部工作目录的 `Makefile` |
| `board/pl30/sha256sums` | 部署脚本在输出包中生成既有板端名称 `SHA256SUMS`，内容保持原样 |
| `board/app/zynq7020.sh` | 部署脚本按运行环境映射为 `Zynq7020.sh` |

`zImage` 为外部厂商内核文件的运行名称，仓库仅保存其身份信息；部署脚本从使用者提供的路径导入。上述大写名称只在生成的工作副本或板端包中出现。

GitHub 仓库地址保持现有名称。历史报告正文与归档记录中的原始路径保留，用于定位原构建和测试文件。
