# 工程状态与待补材料

当前版本为 PL0～30 连续子图加速，来源提交为 `dfd7f4f0c11e4edadc0b1743d16a116c45c8934d`。源码、模型、bit、设备树和实测结果的对应关系见 [provenance.json](provenance.json)。

## 已提供

- 18 份 RTL、PS 推理与 DMA 客户端源码、模型与参数。
- bit、XSA、HWH、设备树、服务和部署准备脚本。
- 97 个 AXIS 激励报文、参考输出、7 轮实板计时、HTTP 图片和返回结果。
- 资源与时序报告、构建入口、设计报告、协作摘录及技能包。
- 双板工程互链、海报和比赛指南；树莓派采集与控制工程独立维护。

## 验证记录

原构建及实板验证见 [submission_validation.json](submission_validation.json)；本次目录与文档整理检查见 [repository_cleanup_validation.json](repository_cleanup_validation.json)。

## TODO

- 归档训练源码、测试集和数据许可，完成当前 PL0～30 版本的完整精度评估。
- 补充匹配原厂 Linux 的源码、补丁、配置及获取说明。
- 补充独立环境重建和整机采集、检测、机械分拣联调记录。
