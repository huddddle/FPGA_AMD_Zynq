# 参赛要求与交付对照

本表按用户提供的《2026 FPGA 创新设计赛道选题指南（AMD）》3.3 自主选题初级组要求整理。它是材料自查，不代替组委会对规则、许可或资格的审查。

本次交付固定为 `convrelu_0～30`，从 0 开始编号，共 31 个卷积节点。更深层研发代码、DMA64 和 SG/批量提交实验不纳入本提交基线。

|要求|仓库入口或证据|当前状态与限制|
|---|---|---|
|GitHub 开源|[提交仓库](https://github.com/huddddle/FPGA_AMD_Zynq)|公开仓库；与开发仓库独立|
|允许再分发的协议|[MIT](../LICENSE)、[许可范围](license_scope.md)|原创代码及文档 MIT；模型、GPL 驱动、NCNN、stb 和 AMD 产物保留各自条款|
|英文路径与标准入口|[命名规则](naming_policy.md)、[只读校验器](../skill/verify_submission.py)|自定义名称小写英文；标准工具名按已确认例外保留，扩展名分隔点保留|
|RTL 与 PS 完整源码|[RTL](../src/rtl)、[PS 软件](../src/ps_software)|18 份 RTL 与已验 bit 的冻结来源绑定；不复制活动研发源码|
|仿真脚本和结果|[仿真说明](../sim/README.md)、[原始回放结果](evidence/submission_rtl_result.json)|生产顶层 97 报文、144920 返回字；含反压及旧路径回归|
|可复现构建入口|[构建说明](../build/README.md)、[Vivado Tcl](../build/build_pl30.tcl)、[PS 编译](../build/build_ps.py)|整理后的 Tcl 已做静态检查；已有原始硬件签核，尚未另做干净环境全链路重建|
|综合、实现和时序报告|[原始报告](../build/reports)、[资源摘要](resource_summary.json)|100 MHz，WNS +0.008 ns、WHS +0.036 ns、DRC 错误 0；新构建必须重新签核|
|上板工程和运行脚本|[配套硬件包](../board/pl30)、[部署准备](../board/prepare_deployment.py)、[运行说明](../board/README.md)|匹配 bit/DT/驱动；厂家内核由使用者提供并按 SHA 核验，不覆盖默认 SD 启动|
|实测输出和比对数据|[实板原始结果](../board/evidence)、[独立黄金输出](../data/reference)|固定输入 CPU 与 PL 使用各自黄金输出；提供下载后逐文件验收命令|
|性能指标|[设计报告](design_report.md)、[指标表](metrics.csv)|同轮七次：纯 PS 1240.163 ms，PL30 869.309 ms；PL30 较 PL21 慢 3.231 ms，如实保留|
|模型、输入和类别|[模型说明](../data/model/README.md)、[数据说明](../data/README.md)|320×320/ReLU/五类；训练代码、完整数据与授权材料仍待补，不能声称可从零重训|
|提示词、回答与纠错轨迹|[实际协作摘录](ai_collaboration.md)、[失败和修正证据](evidence)|提供真实摘录、问题及对应证据；摘要与逐字原话分开，不编造完整聊天|
|可复用技能包|[skill/README.md](../skill/README.md)|场景、使用方法、失效条件、验证效果及可执行校验；尚无跨队伍独立验证|
|通用 PYNQ Skill 加分项|[技能边界](../skill/README.md)|当前使用原生 Linux/NCNN/内核客户端，未实现 PYNQ，不申报该加分能力|
|器件声明|[平台表](../README.md)、[资源摘要](resource_summary.json)|野火 Zynq7020，xc7z020clg400-2，1 GiB DDR|
|推荐工具版本|[构建说明](../build/README.md)|Vivado 2022.2；PS 用户态使用已验 SDK2018.3 ARM32 编译器，内核模块须另匹配厂商构建树|

提交前仍需补齐：匹配厂商内核源码/补丁/配置及公开获取材料、模型训练材料与数据许可、干净环境复现记录、实物分拣闭环证据。固定图功能验证和文件校验不能替代这些材料；本轮不新增全量 mAP。
