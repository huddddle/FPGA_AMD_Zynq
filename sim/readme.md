# 仿真与软件校验

公开AXIS激励含97个报文、两帧完整前向与旧任务回归，原始实证为 [rtl.json](../report/evidence/rtl.json)。压缩激励随包提供；解压、编译和输出仅写到指定工作目录。

**Linux/WSL Bash，先切到仓库根目录：**

```bash
python3 -B sim/run_rtl.py --work-dir /mnt/d/CodexCache/FPGA_AMD_Zynq_rtl-check_2026-11-04_120000 --jobs 2
```

`--work-dir` 指定仓库外中间目录；示例日期时间请换为本次实际时间。`--jobs 2` 限制编译并行度。入口先解压固定激励，再编译完整生产顶层，最后在反压条件下逐字比较返回值。预期97包通过、`compared_words=144920`；失败立即返回非零，日志位于工作目录，不把波形或仿真通过说成实板验收。

需要 Verilator 及 C++ 编译器；原始记录使用 Verilator 5.032。Windows 用户在 WSL Bash 执行上述命令，原生 Windows Python 不直接调用 Linux Verilator。

**PowerShell 或 Bash：**

```text
python -B sim/test_verifier.py --work-dir D:/CodexCache/FPGA_AMD_Zynq_checker_2026-11-04_120000
```

校验工具使用已知 `abc` SHA256 样本，确认单字节篡改和目录越界均被拒绝；另外验证归档 CPU/PL30 输出通过，并确认被改动的 C30 输出失败。只在工作目录内创建测试副本，不改黄金参考或原始实板数据。Linux用户将工作目录改为实际可访问的仓库外路径。文件绑定与下载结果检查见 [verify_submission.py](../skill/verify_submission.py)。
