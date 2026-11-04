# 提交材料对照

依据随附比赛指南 §3.3。系统由 [Zynq 仓库](https://github.com/huddddle/FPGA_AMD_Zynq) 与 [树莓派仓库](https://github.com/Tony-Chen-dot/FPGA-AMD-RaspberryPi) 共同组成。

| 提交内容 | 位置与状态 |
| --- | --- |
| 开源协议 | [MIT](../license)；第三方条款见[许可说明](license_scope.md) |
| 英文小写路径 | [命名说明](naming_policy.md)；文件和结果由校验器检查 |
| RTL / PS 源码 | [src/](../src)；18 份 RTL 与 PL0～30 bit 对应 |
| 树莓派软件 | 配套仓库：采集、HTTP 客户端、UART、看板与语音 |
| 仿真/验证 | [sim/](../sim)、[RTL 结果](evidence/submission_rtl_result.json)；97 报文、144920 返回字 |
| 构建脚本 | [Vivado Tcl](../build/build_pl30.tcl)、[PS 编译](../build/build_ps.py)、[依赖说明](../build/readme.md) |
| 综合与实现 | [build/reports/](../build/reports)、[资源摘要](resource_summary.json)；100 MHz，WNS +0.008 ns，WHS +0.036 ns |
| 上板工程与输出 | [board/](../board)、[参考输出](../data/reference)；厂家内核由外部提供并核验 SHA |
| 性能对比 | [设计报告](design_report.md)、[指标表](metrics.csv)；同条件七轮测试 |
| 模型和数据 | [模型](../data/model/readme.md)、[固定输入](../data/readme.md)；训练材料和完整精度评估待补充 |
| 大模型交互记录 | [开发与整理摘录](ai_collaboration.md)、[本次文档整理记录](repository_cleanup.md)；完整研发记录待汇总 |
| 技能包 | [skill/](../skill/readme.md)：场景、方法、失效条件及验证结果 |
| 器件和组别 | 初级组；大三本科生；野火 Zynq7020，`xc7z020clg400-2` |
| 工具版本 | Vivado 2022.2，版本选择与构建入口见[说明](../build/readme.md) |
| 海报与指南 | [report/materials/](materials/readme.md)；海报与当前 PL30 的实验版本分别注明 |

待补材料统一见[工程状态](submission_status.md)和首页 TODO。当前使用 Linux / NCNN 与自定义内核客户端；PYNQ 适配可作为后续扩展。
