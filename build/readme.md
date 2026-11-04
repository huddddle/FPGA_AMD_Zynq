# 构建、报告与依赖

`reports/` 是真实已验硬件的原始签核报告；`bd/sys_resident.tcl` 保存完整已核验的PS DDR/MIO、复位、DMA与互连参数。新入口移除开发机缓存基础XPR的依赖，直接从该BD和本仓库RTL创建工程。报告中的旧绝对路径是历史来源，不是新入口的依赖。

## 用户态交叉编译

先准备 ARM32 hard-float GCC 和 NCNN 安装目录（含 `include/ncnn/net.h` 与 `lib/libncnn.a`）。已验证组合：Xilinx SDK 2018.3 GCC7.3.1，NCNN提交 `e54f7b1f88434e1d844ea0551b880a1cfb079ce1`。第三方获取见 [NCNN](https://github.com/Tencent/ncnn/tree/e54f7b1f88434e1d844ea0551b880a1cfb079ce1)。

**Windows PowerShell，仓库根目录：**

```powershell
python -B build/build_ps.py --compiler 'D:/Vivado2018_3/SDK/2018.3/gnu/aarch32/nt/gcc-arm-linux-gnueabi/bin/arm-linux-gnueabihf-g++.exe' --ncnn-dir 'C:/Users/huddd/Desktop/Yolo26n/arm32/ncnn-install' --build-dir 'D:/CodexCache/FPGA_AMD_Zynq_ps-build_2026-11-04_120000/arm'
```

三个路径按电脑实际位置设置；工作目录应位于 `D:/CodexCache` 的任务及完整时间命名目录下。程序把源码原样暂存到工作目录，以兼容旧SDK对中文路径的限制；同一次编译生成三个 ARM32 程序：`yolo26_detect`（HTTP 服务调用）、`detection_custom_test`（软件后处理自测）、`y26-continuous30-check`（固定输入 CPU/PL21/PL30 检查）。`--build-dir` 必须在仓库之外。编译不访问开发板、不替换已验收生产二进制；新编译文件仍需运行后处理测试及匹配板端验收。归档的二进制与新编译结果分别保留，不通过覆盖旧二进制来更新原始 SHA 清单。

### NCNN 与编译依赖的身份

需要 Python 3.10 或更高版本、Git，以及与 NCNN 使用相同 ABI 的 ARM32 hard-float 编译器。CPU 为 Cortex-A9/ARMv7-A/NEON；不能用面向 ARM64 的库替代。归档库配置关闭 OpenMP、Vulkan、VFPv4，应用参数固定 `-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -ffp-contract=off`，静态链接 GCC/C++ 支持库，动态依赖板端 glibc。

**PowerShell 或 Bash，在仓库外的依赖目录执行：**

```text
git clone https://github.com/Tencent/ncnn.git
```

该命令下载 NCNN，生成 `ncnn/`；进入其目录后，**同一终端执行：**

```text
git checkout e54f7b1f88434e1d844ea0551b880a1cfb079ce1
```

固定原验证提交，避免默认分支变化；若提交不存在或未下载成功应停止。构建参考 [NCNN 官方 Cortex-A 交叉编译说明](https://github.com/Tencent/ncnn/wiki/how-to-build#build-for-arm-cortex-a-family-with-cross-compiling) 及该提交的 [ARM hard-float 工具链入口](https://github.com/Tencent/ncnn/blob/e54f7b1f88434e1d844ea0551b880a1cfb079ce1/toolchains/arm-linux-gnueabihf.toolchain.cmake)。根据主机配置编译器/sysroot、Cortex-A9 参数，并关闭上述三项后安装；产物必须有 `include/ncnn/net.h`、生成的配置头和 `lib/libncnn.a`。工具链/sysroot 不随本仓库再分发；本轮复用了已验库进行三个应用的重建，没有新做 NCNN 从源码及完整厂商系统的干净重建。

用户态编译器、NCNN 库、板端运行库必须配套。现有库 SHA256 为 `557aee120382fdfd0d1fe84e4136b458817e5af431c4b7c51a42437d76201579`；自行重建可能因路径和工具版本产生不同库字节，仍需核对架构并验证数值，不能仅以库 SHA 不同判定计算错误。

## Vivado重建：GUI和命令行任选

需要 **Vivado2022.2** 和 `xc7z020clg400-2` 器件/IP支持。此流程生成工程、综合、实现、时序覆盖/资源/DRC报告，全部条件通过才导出bit/XSA。不会下载开发板。

GUI入口：打开一个未载入工程的Vivado2022.2窗口，在底部 **Tcl Console** 设置工作目录，再点 **Tools → Run Tcl Script**，选择本仓库 `build/build_pl30.tcl`。目的为用已核验板级BD重建完整系统；所有产物写入工作目录，不能拿旧报告当本次结果。

**Vivado Tcl Console，只设置环境：**

```tcl
set ::env(Y26_BUILD_DIR) {D:/CodexCache/FPGA_AMD_Zynq_hw-build_2026-11-04_120000/vivado}
```

该目录应是新的工作目录；随后通过上述菜单运行脚本。也可以使用等效的批处理入口。

**Windows PowerShell，仓库根目录：**

```powershell
$env:Y26_BUILD_DIR='D:/CodexCache/FPGA_AMD_Zynq_hw-build_2026-11-04_120000/vivado'; New-Item -ItemType Directory -Path $env:Y26_BUILD_DIR -Force | Out-Null; & 'D:/Vivado2022_2/Vivado/2022.2/bin/vivado.bat' -mode batch -source './build/build_pl30.tcl' -notrace -nojournal -log "$env:Y26_BUILD_DIR/build.log"
```

`;` 依次设置环境、创建本次工作目录、启动工具，`&` 调用带路径的程序，`-source` 指定入口，`-log` 保存日志；`-Force` 仅允许工作目录预先存在，脚本仍拒绝已有工程子目录。示例目录中的日期时间请换为本次实际时间。入口固定100MHz、AltSpreadLogic_high/Explore和postroute AggressiveExplore；检查WNS/WHS、12类时序覆盖、零布线错误、DRC、单PE、DSP/BRAM与部分和存储。负裕量时停止，不导出bit；应分析本次失败路径，按目标时钟约束修复路径。预期产物在工作目录 `reports/`，新bit需重新核验DT、身份绑定和板端数值。

本次仓库整理只对移植后的Tcl进行语法完整性和依赖核查，**没有新运行这套Vivado重建**；已有100MHz报告来自冻结版本。布局布线不保证跨机器逐字节重现bit或复现相同的8ps余量，验收以本次完整报告为准。

## Linux内核客户端

已验收 `.ko` 的 vermagic 为 `5.15.0-xilinx SMP preempt mod_unload modversions ARMv7 p2v8`，V2每方向512KiB，两块缓冲共1MiB；详见 [driver_abi.json](../board/pl30/driver_abi.json)。不能用用户态SDK2018直接构建这个内核模块。

**Ubuntu Bash，先设置实际匹配内核构建树及输出目录：**

```bash
mkdir -p "$Y26_MODULE_OUT" && cp src/ps_software/loopback/y26_dma_client.c src/ps_software/loopback/y26_dma_uapi.h "$Y26_MODULE_OUT/" && cp src/ps_software/loopback/makefile "$Y26_MODULE_OUT/Makefile" && make -C "$KERNEL_BUILD" M="$Y26_MODULE_OUT" ARCH=arm CROSS_COMPILE=arm-xilinx-linux-gnueabi- modules
```

`Y26_MODULE_OUT` 为仓库外工作目录，`KERNEL_BUILD` 必须包含厂商相同配置、生成头文件和Module.symvers；`&&` 保证前一步成功再继续。该命令生成模块，不加载模块。版本字符串相同并不保证CRC兼容，重建后须核对符号CRC及实际内核。

原厂系统来源为野火AC7020资料包 `0-快速测试手册/ZYNQ镜像/zynq.img`，本机原始路径 `F:/DevelopmentBoardResource/YeHuoAC7020`。完整镜像、PetaLinux安装器及匹配的厂商内核构建树/Module.symvers不随此仓库重复分发。可从[野火官方](https://www.embedfire.com/)对应板卡资料渠道取得；本发布未核实一个可匿名下载的完整匹配内核源码/SDK链接。当前发布只记录已验原厂zImage的身份（4503288字节，SHA311d2c1f…），不在新开源仓库重复分发该二进制；部署时从现有厂家镜像/已有zImage导入并完整核验。保留配套自有驱动源码和ABI记录，TODO：补充匹配的原厂 Linux 源码、补丁及构建配置。

## 小写文件名与 CMake

仓库中的原生构建模板为 `cmakelists.txt`。需要使用 CMake 时，先生成仓库外的源码工作副本。

**PowerShell，在仓库根目录：**

```powershell
python -B build/build_ps.py --prepare-only --build-dir 'D:/CodexCache/zynq_native_2026-11-04_170000'
```

`--prepare-only` 只复制源码，并在工作副本内恢复 CMake 标准名称 `CMakeLists.txt`；`--build-dir` 必须在仓库外。示例目录换成本次任务与时间。生成的 `source/app/native/` 和 `source/conv_accel/native/` 可作为 CMake 源目录，配置时另行提供 NCNN 与工具链。正常 PS 交叉编译入口也会自动执行相同的准备步骤。

## 工具版本说明

本工程采用 Vivado 2022.2，以匹配现有 Zynq-7020 工程和板端 PetaLinux 2022.2 环境。比赛指南 §3.3.3.1 推荐 Vivado / Vitis 2026.1 或 2025.2，也允许其他版本，要求在报告中说明并提供可复现脚本。当前 Vivado Tcl 与 PS 编译入口均保存在本目录；新环境重建与上板复验记录仍需补充。
