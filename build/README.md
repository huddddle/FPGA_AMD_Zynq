# 构建、报告与依赖

`reports/` 是真实已验硬件的原始签核报告；`bd/sys_resident.tcl` 保存完整已核验的PS DDR/MIO、复位、DMA与互连参数。新入口移除开发机缓存基础XPR的依赖，直接从该BD和本仓库RTL创建工程。报告中的旧绝对路径是历史来源，不是新入口的依赖。

## 用户态交叉编译

先准备 ARM32 hard-float GCC 和 NCNN 安装目录（含 `include/ncnn/net.h` 与 `lib/libncnn.a`）。已验证组合：Xilinx SDK 2018.3 GCC7.3.1，NCNN提交 `e54f7b1f88434e1d844ea0551b880a1cfb079ce1`。第三方获取见 [NCNN](https://github.com/Tencent/ncnn/tree/e54f7b1f88434e1d844ea0551b880a1cfb079ce1)。

**Windows PowerShell，仓库根目录：**

```powershell
python -B build/build_ps.py --compiler 'D:/Vivado2018_3/SDK/2018.3/gnu/aarch32/nt/gcc-arm-linux-gnueabi/bin/arm-linux-gnueabihf-g++.exe' --ncnn-dir 'C:/Users/huddd/Desktop/Yolo26n/arm32/ncnn-install' --build-dir 'D:/CodexCache/y26_submission_ps'
```

三个路径按电脑实际位置设置。程序把源码原样暂存到工作目录，以兼容旧SDK对中文路径的限制；用相同参数生成 ARM32 `yolo26_detect` 与 `detection_custom_test`。`--build-dir` 必须在仓库之外。编译不访问开发板、不替换已验收生产二进制；新编译文件仍需运行后处理测试及匹配板端验收。

## Vivado重建：GUI和命令行任选

需要 **Vivado2022.2** 和 `xc7z020clg400-2` 器件/IP支持。此流程生成工程、综合、实现、时序覆盖/资源/DRC报告，全部条件通过才导出bit/XSA。不会下载开发板。

GUI入口：打开一个未载入工程的Vivado2022.2窗口，在底部 **Tcl Console** 设置工作目录，再点 **Tools → Run Tcl Script**，选择本仓库 `build/build_pl30.tcl`。目的为用已核验板级BD重建完整系统；所有产物写入工作目录，不能拿旧报告当本次结果。

**Vivado Tcl Console，只设置环境：**

```tcl
set ::env(Y26_BUILD_DIR) {D:/CodexCache/y26_submission_gui}
```

该目录应是新的工作目录；随后通过上述菜单运行脚本。也可以使用等效的批处理入口。

**Windows PowerShell，仓库根目录：**

```powershell
$env:Y26_BUILD_DIR='D:/CodexCache/y26_submission_build'; & 'D:/Vivado2022_2/Vivado/2022.2/bin/vivado.bat' -mode batch -source './build/build_pl30.tcl' -notrace -nojournal -log 'D:/CodexCache/y26_submission_build.log'
```

`;` 先设置环境再启动工具，`&` 调用带路径的程序，`-source` 指定入口，`-log` 保存日志。入口固定100MHz、AltSpreadLogic_high/Explore和postroute AggressiveExplore；检查WNS/WHS、12类时序覆盖、零布线错误、DRC、单PE、DSP/BRAM与部分和存储。负裕量时停止，不导出bit；应分析本次失败路径，不降低约束伪装通过。预期产物在工作目录 `reports/`，新bit需重新核验DT、身份绑定和板端数值。

本次仓库整理只对移植后的Tcl进行语法完整性和依赖核查，**没有新运行这套Vivado重建**；已有100MHz报告来自冻结版本。布局布线不保证跨机器逐字节重现bit或复现相同的8ps余量，验收以本次完整报告为准。

## Linux内核客户端

已验收 `.ko` 的 vermagic 为 `5.15.0-xilinx SMP preempt mod_unload modversions ARMv7 p2v8`，V2每方向512KiB，两块缓冲共1MiB；详见 [driver_abi.json](../board/pl30/driver_abi.json)。不能用用户态SDK2018直接构建这个内核模块。

**Ubuntu Bash，先设置实际匹配内核构建树及输出目录：**

```bash
mkdir -p "$Y26_MODULE_OUT" && cp src/ps_software/loopback/y26_dma_client.c src/ps_software/loopback/y26_dma_uapi.h src/ps_software/loopback/Makefile "$Y26_MODULE_OUT/" && make -C "$KERNEL_BUILD" M="$Y26_MODULE_OUT" ARCH=arm CROSS_COMPILE=arm-xilinx-linux-gnueabi- modules
```

`Y26_MODULE_OUT` 为仓库外工作目录，`KERNEL_BUILD` 必须包含厂商相同配置、生成头文件和Module.symvers；`&&` 保证前一步成功再继续。该命令生成模块，不加载模块。版本字符串相同并不保证CRC兼容，重建后须核对符号CRC及实际内核。

原厂系统来源为野火AC7020资料包 `0-快速测试手册/ZYNQ镜像/zynq.img`，本机原始路径 `F:/DevelopmentBoardResource/YeHuoAC7020`。完整镜像、PetaLinux安装器及匹配的厂商内核构建树/Module.symvers不随此仓库重复分发。可从[野火官方](https://www.embedfire.com/)对应板卡资料渠道取得；本发布未核实一个可匿名下载的完整匹配内核源码/SDK链接。当前发布只记录已验原厂zImage的身份（4503288字节，SHA311d2c1f…），不在新开源仓库重复分发该二进制；部署时从现有厂家镜像/已有zImage导入并完整核验。保留配套自有驱动源码和ABI记录，不宣称已具备完整原厂Linux从源码重建条件。
