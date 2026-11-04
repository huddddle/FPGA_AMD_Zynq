# Zynq-7020 仓库交接

更新日期：2026-11-04。本次任务为双板开源仓库整理，用户已确认维护本仓库的 `handoff.md`。

## 工程与入口

- 架构：RTL + ARM32 NCNN + HTTP；配套树莓派仓库负责采集与执行器。
- 安装、构建、启动与依赖见 `readme.md`、`build/readme.md`、`board/readme.md`。
- 两仓库地址与分工见首页；比赛指南和海报集中在 Zynq 的 `report/materials/`。

## 本次修改

- 重写首页并增加双板互链，简化内部流程措辞，将缺件整理为 TODO。
- 文件名统一小写，更新链接与工具入口；保留扩展名和 Git 隐藏文件的点号。
- 补充目录对照、许可说明、技能与协作记录。

## 验证与下一步

新增 CMake 源码准备测试、固定结果校验、篡改拒绝与部署包原始 SHA 校验通过；路径/链接与清单结果见 `report/repository_cleanup_validation.json`。本次保留原 RTL、模型、bit、设备树、驱动及实板输出的字节，未重新运行 Vivado 或操作硬件。当前 TODO 见首页。

后续继续整理可使用 `grill-with-docs` 与 `handoff` 技能，路径为 `C:/Users/huddd/.codex/skills/<name>/SKILL.md`；行为变更按 `tdd` 验证。工作中间文件放在 `D:/CodexCache` 的独立任务时间目录。
