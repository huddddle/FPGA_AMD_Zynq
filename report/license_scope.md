# 许可证范围与来源

根LICENSE为 **MIT，Copyright (c) 2026 Landon Yang**，适用于权利人拥有并以该许可发布的原创RTL、原创用户态代码、整理脚本、技能模板与文档。它不覆盖下面已有独立许可的组件，也不声称替上游权利人授予新权利。

|范围|条款/来源|本仓库处理|
|---|---|---|
|原创RTL、PS用户态与整理文档|MIT|根LICENSE|
|YOLO26n部署模型及其派生权重/参数报文|依Ultralytics上游模型许可，非根MIT|data/model/license_agpl_3_0.txt及模型说明；不假定企业授权|
|NCNN与其依赖|BSD及所列依赖条款|保留src/ps_software/app/native/third_party/ncnn/LICENSE.txt|
|stb|其文件内MIT/公共领域双许可|保留文件原始许可正文|
|DMA Linux内核客户端|GPL-2.0-only|保留源文件SPDX、源码、UAPI和GPL2正文|
|原厂Linux zImage|Linux及对应组件原许可|明确为只保留原厂内核身份与ABI；通过外部导入提供，不重新分发或标MIT|
|Vivado生成BD/HWH/XSA/bit与工具报告|适用AMD工具、IP及原始生成声明|不删原始声明，不声称这些第三方部分均是个人原创MIT|

上游说明：[Ultralytics](https://www.ultralytics.com/license)、[NCNN许可证](https://github.com/Tencent/ncnn/blob/e54f7b1f88434e1d844ea0551b880a1cfb079ce1/LICENSE.txt)、[Linux源码与许可](https://github.com/Xilinx/linux-xlnx)。随附许可证文本的内容SHA受提交清单约束。

当前未收齐模型训练过程与数据授权材料、完整厂商匹配内核构建树及其特定补丁，因此不把本说明称为完整第三方许可审计或完整对应源代码交付。取得材料后应补充来源/版本与获取说明；内核和模型不因放入MIT仓库就改变原许可。
