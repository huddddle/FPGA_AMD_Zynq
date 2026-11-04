# 上板包与实板证据

`pl30/` 保存冻结的bit、DTB/DTS、原内核身份、启动脚本、512KiB客户端、参数、固定输入与检查程序；`sys_resident.xsa`含同一bit，`sys.hwh`从XSA原样提取。`app/`提供服务，模型单独放在 `data/model`，相同参数只存一份，通过部署映射组合。`evidence/`是原始实板记录，不是本次重新上板结果。

以下命令供开发板空闲时复现；本次仓库整理没有连接开发板或起停服务。

## 1. 准备并上传

**电脑PowerShell，在仓库根目录：**

```powershell
python -B board/prepare_deployment.py --output 'D:/FPGA_AMD_Zynq_release/pl30' --kernel 'D:/vendor_assets/zImage'
```

先把 `--kernel` 改为现有厂家zImage的位置，程序核验其SHA及配套身份；缺失或不匹配时不创建输出。随后生成 `Zynq7020_deploy/` 与 `y26_continuous30/` 两个目录，恢复既有板端文件名并检查全部原清单SHA。输出目录已存在则停止，避免覆盖上一次材料；不进行SSH或PL配置。

**电脑PowerShell：**

```powershell
scp -O -r 'D:/FPGA_AMD_Zynq_release/pl30/Zynq7020_deploy' 'D:/FPGA_AMD_Zynq_release/pl30/y26_continuous30' root@192.168.10.111:/home/root/
```

`-O` 使用兼容Dropbear的旧SCP协议，`-r` 上传两目录；会写入远端同名目录，先保留现有板端自定义配置。IP和账号按现场设置，密码只在本地输入。该命令不重启、不配置PL。上传后在板端核验 `y26_continuous30/SHA256SUMS`，不要只确认文件存在。

## 2. 临时加载配套硬件

**开发板Linux sh，保存工作后：**

```sh
sync && /sbin/reboot
```

`sync`刷新文件系统，成功后重启并结束当前进程；在串口按键停在 `Zynq>`。这不会改默认SD启动文件。

**U-Boot串口：**

```text
mmc dev 0 && mmc rescan && ext4load mmc 0:2 0x04000000 /home/root/y26_continuous30/boot_continuous30.scr && iminfo 0x04000000
```

依次选择SD、重新识别、只读脚本到DDR并校验头/CRC，预期 `Verifying Checksum ... OK`。`&&` 前一步失败便停止；不是Linux shell命令，不写SD。

**U-Boot串口，核对脚本后：**

```text
source 0x04000000
```

配置配套bit，使用匹配DT和原内核启动原SD根分区。预期机器型号 `Embedfire Zynq7020 continuous0to30 shared INT8 fusion`，DMA正常探测、无持续RTC超时。原SD默认保留，普通重启后要再次临时选择；不执行 `saveenv`，不把单独下载bit当完整Linux上板。

## 3. 数值检查与服务

**开发板Linux sh：**

```sh
cd /home/root/y26_continuous30 && sha256sum -c SHA256SUMS && chmod +x y26-continuous30-check /home/root/Zynq7020_deploy/yolo26_detect
```

`cd`成功后核验全部发布文件，预期每项OK，再为检查工具和推理程序添加执行权限（Windows上传后可能没有执行位）。`&&`保证校验失败时不继续。随后在匹配系统中加载客户端。

**开发板Linux sh，仅当前尚未加载该模块时：**

```sh
/sbin/insmod /home/root/y26_continuous30/y26_dma_client.ko
```

申请DMA通道和双向一致性缓冲区，预期日志ready及设备 `/dev/y26_dma_loopback`。若已加载则不重复执行，不强制卸载忙碌模块。不要用旧10012回环报文测试本生产控制器。

**开发板Linux sh，HTTP尚未运行时：**

```sh
mkdir -p /home/root/y26_continuous30/submission_check && taskset -c 1 /home/root/y26_continuous30/y26-continuous30-check --backend pl30 --param /home/root/Zynq7020_deploy/model.ncnn.param --bin /home/root/Zynq7020_deploy/model.ncnn.bin --rgb /home/root/y26_continuous30/input.rgb --package /home/root/y26_continuous30 --output-dir /home/root/y26_continuous30/submission_check --warmup 0 --runs 1 --capture 1
```

创建结果目录后固定CPU1执行一次真实PL前向，保存C10/C20/C30整数、尾网与计时。预期47事务、无硬件错误；`conv30.i8` 等于 `data/reference/conv30.i8`，尾网SHA为 `6cd6b3bd357c3c46688870b85d83bd34de92d55288cd429160f47224ca09427a`。单次耗时不作为7轮均值。

**电脑 PowerShell，先创建实验结果的长期保存目录：**

```powershell
New-Item -ItemType Directory -Path 'D:/FPGA_AMD_Zynq_results' -Force
```

只创建电脑上的结果父目录；`-Force` 允许父目录已存在，不删除已有文件。首次取回本次结果时，**同一 PowerShell 执行：**

```powershell
scp -O -r root@192.168.10.111:/home/root/y26_continuous30/submission_check 'D:/FPGA_AMD_Zynq_results/pl30_check'
```

`-r` 下载检查目录，`-O` 兼容板端 Dropbear；目标 `pl30_check` 应尚不存在，复测时换新目录名，以免把前后结果混在一起。命令只读取板端结果，不重新执行推理。

**电脑 PowerShell 或 Bash，在仓库根目录执行：**

```text
python -B skill/verify_submission.py --results D:/FPGA_AMD_Zynq_results/pl30_check --backend pl30
```

先核验提交包身份，再比较 `conv10.i8`、`conv20.i8`、`conv30.i8` 和 `output.f32`，最后核对 `report.json` 的后端、47事务、TX/RX字节数和错误状态。预期 `inference_results.passed=true`、`files_checked=4`；任何缺件、数值不匹配或报告边界不符均返回非零。比较的是冻结固定输入，换输入后不能沿用这组黄金数据。该检查不写板端，也不代表完整数据集识别精度评估。

**开发板Linux sh：**

```sh
sh /home/root/Zynq7020_deploy/Zynq7020.sh
```

检查硬件/参数并启动或复用HTTP服务，仅显示之后的新日志。Ctrl+C退出监视，后台继续。默认端口8080，配置在network.conf；HTTP和独立检查程序不要同时使用共享PL状态。

**电脑PowerShell：**

```powershell
curl.exe --fail --max-time 10 'http://192.168.10.111:8080/health'
```

只查状态，预期 `backend=ncnn_pl30`、31个加速节点；`--max-time`限制请求总时长，失败先查网络和服务。

**电脑PowerShell，在仓库根目录：**

```powershell
curl.exe --fail-with-body --max-time 30 -F 'image_file=@data/input_300.jpg;type=image/jpeg' 'http://192.168.10.111:8080/predict'
```

实际上传示例图片并推理，保存本次结果；`-F`构造文件字段，预期同一连接返回JSON及中文日志。这里只验证单图功能，不代表数据集mAP或整机分拣成功率。历史图和返回值见 [HTTP证据](evidence/service/http_verification.json)。
