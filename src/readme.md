# 源码范围

`rtl/` 的18个文件逐字节对应冻结审阅清单，顶层为 `y26_axis_continuous30_top`。只保留实际配套前段，未把开发中后层电路混入已验收 bit。

`ps_software/app/native/` 为图像预处理、检测后处理和入口；`ps_software/conv_accel/native/` 为报文、整数接口和前段调度；`ps_software/loopback/` 是DMA内核客户端及UAPI。客户端仍保留 GPL-2.0-only 标识。

用户态已验构建入口是 [build_ps.py](../build/build_ps.py)。CMake入口补齐原生构建所用的 resident_prefix.cpp，不能将未运行过的CMake流程冒充已通过。来源、移动及必要入口适配见 [provenance.json](../report/provenance.json)。
