# Run manually from the U-Boot prompt, not from Linux.
# Only RAM environment variables change; no saveenv or SD writes.
echo Y26: loading experiment files from SD ext4 partition 0:2
setenv y26_dir /home/root/y26_continuous30

if ext4load mmc 0:2 0x01000000 ${y26_dir}/sys_wrapper.bit; then
    if itest ${filesize} == 0x3dbb67; then
        setenv y26_bitsize ${filesize}
    else
        echo Y26 FAIL: bit size mismatch
        exit 1
    fi
else
    echo Y26 FAIL: bit file not loaded
    exit 1
fi

if ext4load mmc 0:2 0x01f00000 ${y26_dir}/continuous30.dtb; then
    if itest ${filesize} == 0x371e; then
        fdt addr 0x01f00000 || exit 1
    else
        echo Y26 FAIL: DT size mismatch
        exit 1
    fi
else
    echo Y26 FAIL: DT not loaded
    exit 1
fi

if ext4load mmc 0:2 0x02000000 ${y26_dir}/zImage; then
    if itest ${filesize} == 0x44b6f8; then
        echo Y26: all three boot files loaded
    else
        echo Y26 FAIL: kernel size mismatch
        exit 1
    fi
else
    echo Y26 FAIL: kernel not loaded
    exit 1
fi

if fpga loadb 0 0x01000000 ${y26_bitsize}; then
    echo Y26: PL configured, starting original kernel with continuous30 DT
else
    echo Y26 FAIL: FPGA configuration failed
    exit 1
fi

setenv bootargs 'console=ttyPS0,115200 root=/dev/mmcblk0p2 rw rootfstype=ext4 rootwait mtdparts=spi0.0:6M(boot),-(space) board=zynq7020'
bootz 0x02000000 - 0x01f00000
echo Y26 FAIL: bootz returned; cold restart for the factory default boot
exit 1
