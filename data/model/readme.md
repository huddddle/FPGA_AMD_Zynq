# YOLO26n部署模型与许可

模型名称 **YOLO26n / ReLU320**。输入 `1×3×320×320`，输出 `1×9×2100`，类别顺序：ca_shang、zang_wu、zhe_zhou、zhen_kong、zheng_chang。网络NCNN文件保留FP32，前段使用配套INT16权重/INT8特征，不把“输出INT8”写成全模型INT8。

|文件|SHA256|
|---|---|
|model.ncnn.param|424b3eef2f1b90d8b9899361462d636082b7809eb186e0782c2051e77f990c4e|
|model.ncnn.bin|2e293e8f492e50f4695c8d0d338f4dbccc62527570db9debaa7cd6cdb8dabf74|

部署后端是NCNN，生产选择ncnn_pl30；上游模型框架为 [Ultralytics](https://github.com/ultralytics/ultralytics)。依据[上游许可说明](https://www.ultralytics.com/license)，模型及由其导出的权重不被本仓库原创代码的MIT许可重新授权；随附 `license_agpl_3_0.txt` 为上游许可证文本。是否存在其他单独授权应按权利人实际条款核对，本仓库不假定已购买企业许可。

本发布冻结现有部署文件，尚未收齐训练代码、训练数据来源及框架精确训练提交；因此能核对部署模型身份，但不声称可从零重训或量化后的整体精度无损。
