# 命名与目录口径

按用户提供的3.3提交规范整理。自定义目录/文件主体采用小写英文、数字、下划线或连字符；扩展名以及.gitignore等隐藏文件的点保留，中文只在正文与注释。

用户已确认工具标准名称例外：README.md、LICENSE、LICENSE.txt、AGENTS.md、HANDOFF.md、CMakeLists.txt、Makefile、SHA256SUMS、zImage；Dockerfile、MODEL.md、REPORT.md若使用也按规范原名。校验脚本只豁免这些明确名称，不豁免任意大写文件。

自定义启动脚本在仓库为board/app/zynq7020.sh，部署时依映射复制为既有Linux运行入口Zynq7020.sh；它不作为本仓库自定义大写文件例外。运行产生的InferenceResult在板端，不是提交路径。

仓库名FPGA_AMD_Zynq由用户明确指定；电脑上层中文目录不属于仓库内部命名。开发仓库不迁移不改名。原始报告正文中的旧中文路径/绝对路径保留来源含义，不代表新构建入口依赖这些位置。
