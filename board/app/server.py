#!/usr/bin/env python3
"""HTTP image upload -> existing ARM32 NCNN program -> detection JSON."""
import argparse
import hashlib
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import math
from pathlib import Path
import signal
import subprocess
import uuid

ROOT = Path(__file__).resolve().parent
INPUT_SIZE = 320
MAX_UPLOAD = 16 * 1024 * 1024
CHINESE_TYPES = {"ca_shang": "擦伤", "zang_wu": "脏污", "zhe_zhou": "褶皱",
                 "zhen_kong": "针孔", "zheng_chang": "正常"}
BACKEND = "pl30"


def backend_description(backend):
    if backend == "pl30":
        return {"backend": "ncnn_pl30", "pl_acceleration": True,
                "precision": "INT16 MAC / INT8 fused conv0-30 + FP32 remainder",
                "accelerated_layers": ["convrelu_" + str(i) for i in range(31)],
                "resident_subgraphs": [[0, 30]], "ddr_boundaries": [],
                "final_skip_outputs": ["conv10", "conv20"]}
    if backend == "pl21":
        return {"backend": "ncnn_pl21", "pl_acceleration": True,
                "precision": "INT16 MAC / INT8 fused conv0-21 + FP32 remainder",
                "accelerated_layers": ["convrelu_" + str(i) for i in range(22)],
                "resident_subgraphs": [[0, 6], [7, 11], [12, 21]],
                "ddr_boundaries": ["after_conv6", "after_conv11"]}
    if backend not in ("cpu", "pl3"):
        raise ValueError("Unsupported backend")
    return {"backend": "ncnn_pl3" if backend == "pl3" else "ncnn_cpu",
            "pl_acceleration": backend == "pl3",
            "precision": "INT16 MAC / INT8 fused prefix + FP32 remainder" if backend == "pl3" else "FP32",
            "accelerated_layers": ["convrelu_0", "convrelu_1", "convrelu_2"] if backend == "pl3" else []}


def validate_backend_report(report, backend):
    if report.get("backend") != backend or report.get("pl_acceleration") != (backend in ("pl3", "pl21", "pl30")):
        raise ValueError("Inference backend mismatch; refusing to label CPU output as PL")
    if backend == "pl30":
        p = report.get("pl30_profile", {})
        expected = {"transactions": 47, "tx_bytes": 2911888, "rx_bytes": 289792,
                    "hardware_errors": 0, "feature_ddr_reimports": 0}
        if report.get("accelerated_layers") != backend_description(backend)["accelerated_layers"] or any(p.get(k) != v for k, v in expected.items()):
            raise ValueError("Incomplete continuous PL0-30 execution evidence")
    if backend == "pl21":
        p = report.get("pl21_profile", {})
        expected = {"transactions": 34, "tx_bytes": 2114768, "rx_bytes": 437312, "hardware_errors": 0}
        if report.get("accelerated_layers") != backend_description(backend)["accelerated_layers"] or any(p.get(k) != v for k, v in expected.items()):
            raise ValueError("Incomplete PL0-21 execution evidence")


def format_stage_lines(request_id, report):
    t = report["timing_ms"]
    prefix = f"[请求 {request_id}][阶段计时]"
    lines = [f"{prefix} 解码 {t['decode']:.2f}；预处理 {t['preprocess']:.2f}；模型加载 {t['model_load']:.2f} 毫秒"]
    if "pl30_profile" in report:
        p = report["pl30_profile"]
        lines.append(f"{prefix} PL卷积0～30连续路径 {t['prefix_mean']:.2f}；PS余网 {t['remaining_mean']:.2f} 毫秒")
        lines.append(f"{prefix} 0～6计算/等待 {p['graph_wait_ms']:.2f}；7～10 {p['middle_ms']:.2f}；11 {p['conv11_ms']:.2f} 毫秒")
        lines.append(f"{prefix} 12～20 {p['deep_run_ms']:.2f}；21 {p['conv21_ms']:.2f}；22～30 {p['block22_ms']:.2f} 毫秒")
        lines.append(f"{prefix} 片上布局整理：6出口 {p['link6_ms']:.2f}；11出口 {p['link11_ms']:.2f}；21出口 {p['link21_ms']:.2f} 毫秒；中间特征不经DDR重导入")
        lines.append(f"{prefix} 最终旁路及INT8→FP32恢复 {p['restore_ms']:.2f} 毫秒；DMA {p['transactions']}次，发送 {p['tx_bytes']}、接收 {p['rx_bytes']} 字节；硬件错误 {p['hardware_errors']}")
    elif "pl21_profile" in report:
        p = report["pl21_profile"]
        lines.append(f"{prefix} PL卷积0～21完整路径 {t['prefix_mean']:.2f}；PS余网 {t['remaining_mean']:.2f} 毫秒")
        lines.append(f"{prefix} 0～6等待 {p['graph_wait_ms']:.2f}；7～10等待 {p['middle_ms']:.2f}；11分块 {p['conv11_blocks_ms']:.2f} 毫秒")
        lines.append(f"{prefix} 12～20等待 {p['deep_run_ms']:.2f}；21分块 {p['layer21_blocks_ms']:.2f}；长期旁路回传/恢复与兼容转换已计入完整路径")
        lines.append(f"{prefix} DMA事务 {p['transactions']}；发送 {p['tx_bytes']} 字节；接收 {p['rx_bytes']} 字节；硬件错误 {p['hardware_errors']}")
        lines.append(f"{prefix} 偏置/重定标/ReLU在PL；接回FP32余网时保留兼容转换；PL内部计数嵌套在等待中")
    elif "prefix_mean" in t:
        lines.append(f"{prefix} PL前三层路径 {t['prefix_mean']:.2f}；PS余网 {t['remaining_mean']:.2f} 毫秒")
        p = report["prefix_profile"]
        lines.append(f"{prefix} 输入复制/编码 {p['encode_ms']:.2f}；传输与等待 {p['transfer_and_wait_ms']:.2f}；"
                     f"布局与INT8→FP32兼容 {p['layout_and_compatibility_ms']:.2f} 毫秒；"
                     f"PL任务 {p['pl_job_cycles_nested']} 周期（嵌套在等待中，不重复相加）")
    lines.append(f"{prefix} 检测后处理 {t['postprocess']:.2f} 毫秒；以上不包含HTTP传输时间")
    return lines


def preflight(backend, hardware_only=False):
    """Read-only checks. Never program PL, load modules or silently fall back."""
    if backend == "cpu":
        return
    manifest = json.loads((ROOT / ({"pl30": "pl30_manifest.json", "pl21": "pl21_manifest.json", "pl3": "pl3_manifest.json"}[backend])).read_text(encoding="utf-8"))
    for name, digest in manifest["sha256"].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"{backend} model/parameters/binary SHA256 mismatch: {name}")
    command = [str(ROOT / "yolo26_detect"), "--check-runtime", "--backend", backend]
    if backend == "pl30":
        command += ["--parameters", str(ROOT / "pl30")]
    if hardware_only:
        command.append("--hardware-only")
    result = subprocess.run(command, capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "PL runtime unavailable")


def inference_command(image_path):
    command = [str(ROOT / "yolo26_detect"), "--param", str(ROOT / "model.ncnn.param"),
               "--bin", str(ROOT / "model.ncnn.bin"), "--labels", str(ROOT / "label_list"),
               "--size", str(INPUT_SIZE), "--image", str(image_path), "--output-root",
               str(ROOT / "InferenceResult"), "--context", "board", "--runs", "1", "--warmup", "0",
               "--backend", BACKEND]
    if BACKEND == "pl3":
        command += ["--parameters", str(ROOT / "parameters_three.txt")]
    elif BACKEND in ("pl21", "pl30"):
        command += ["--parameters", str(ROOT / BACKEND)]
    return command


def read_network_config():
    settings = {}
    for line in (ROOT / "network.conf").read_text(encoding="utf-8").splitlines():
        line = line.partition("#")[0].strip()
        if line:
            key, value = line.split("=", 1)
            settings[key.strip()] = value.strip()
    return settings


def build_response(detections, inference_ms, original_wh):
    """Translate internal NCNN records to the documented Raspberry Pi contract."""
    width, height = original_wh
    if width <= 0 or height <= 0 or not math.isfinite(inference_ms) or inference_ms < 0:
        raise ValueError("Invalid frame dimensions or inference time")
    result = []
    for detection in detections:
        name, score, loc = detection["class_name"], detection["confidence"], detection["xyxy"]
        if (not name or not math.isfinite(score) or not 0 <= score <= 1 or len(loc) != 4
                or not all(math.isfinite(value) for value in loc)
                or not 0 <= loc[0] < loc[2] <= width
                or not 0 <= loc[1] < loc[3] <= height):
            raise ValueError("Invalid detection: expected class_name, score and original-image xyxy")
        result.append({"class_name": name, "score": score, "loc": list(loc)})
    return {"inference_ms": inference_ms, "result": result}


def format_result_lines(request_id, detections, inference_ms):
    """Render readable terminal results while leaving the HTTP schema intact."""
    prefix = f"[请求 {request_id}]"
    lines = [f"{prefix}[3/4] 推理完成；推理用时：{inference_ms:.2f} 毫秒"]
    if not detections:
        lines.append(f"{prefix}[检测结果] 未检出目标")
    else:
        lines.append(f"{prefix}[检测结果] 共检出 {len(detections)} 个目标")
        for index, detection in enumerate(detections, 1):
            name = CHINESE_TYPES.get(detection["class_name"], detection["class_name"])
            kind = "检测类型" if name == "正常" else "缺陷类型"
            position = ", ".join(f"{value:.2f}" for value in detection["xyxy"])
            lines.append(f"{prefix}[目标 {index}] {kind}：{name}；"
                         f"置信度：{detection['confidence']:.3f}；位置：[{position}]")
    return lines


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return True
        except (BrokenPipeError, ConnectionResetError, TimeoutError) as error:
            print(f"[通信失败] 对端 {self.client_address[0]} 已断开，未完成结果返回；"
                  f"请检查客户端读取超时。{type(error).__name__}", flush=True)
            return False

    def do_GET(self):
        if self.path == "/health":
            labels = (ROOT / "label_list").read_text(encoding="utf-8").splitlines()
            self.reply(200, {"status": "ready", **backend_description(BACKEND), "input_size": INPUT_SIZE,
                             "activation": "ReLU", "num_classes": len(labels),
                             "expected_upper_ip": read_network_config()["UPPER_IP"],
                             "response_mode": "same_http_connection"})
        else:
            self.reply(404, {"error": "Use POST /predict or GET /health"})

    def do_POST(self):
        if self.path != "/predict":
            self.reply(404, {"error": "Use POST /predict"})
            return
        content_type = self.headers.get("Content-Type", "")
        if not content_type.lower().startswith("multipart/form-data"):
            self.reply(400, {"error": "Expected multipart/form-data with image_file"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.reply(400, {"error": "Invalid Content-Length"})
            return
        if length > MAX_UPLOAD:
            self.reply(413, {"error": "Upload exceeds 16 MiB"})
            return
        if length <= 0:
            self.reply(400, {"error": "Missing image_file"})
            return
        self.connection.settimeout(60)
        try:
            body = self.rfile.read(length)
            message = BytesParser(policy=policy.default).parsebytes(
                ("MIME-Version: 1.0\r\nContent-Type: " + content_type + "\r\n\r\n").encode("utf-8") + body)
            image = next((part.get_payload(decode=True) for part in message.walk()
                          if part.get_content_disposition() == "form-data"
                          and part.get_param("name", header="content-disposition") == "image_file"), None)
            if not image:
                self.reply(400, {"error": "Missing image_file"})
                return
        except (OSError, ValueError) as error:
            self.reply(400, {"error": str(error)})
            return

        request_id = uuid.uuid4().hex[:12]
        peer_ip = self.client_address[0]
        expected_ip = read_network_config()["UPPER_IP"]
        print(f"[请求 {request_id}][1/4] 接收图片成功，{len(image)} 字节；来源：{peer_ip}", flush=True)
        if peer_ip != expected_ip:
            print(f"[请求 {request_id}][来源核对] 配置上位机为 {expected_ip}，本次为 {peer_ip}；"
                  "响应仍返回本次请求连接", flush=True)
        uploads = ROOT / "uploads"
        uploads.mkdir(exist_ok=True)
        image_path = uploads / (request_id + ".image")
        image_path.write_bytes(image)
        command = inference_command(image_path)
        path_name = {"pl30": "PL卷积0～30（31个卷积节点）连续片上执行＋偏置/定点缩放/ReLU，PS执行余网", "pl21": "PL卷积0～21（22个卷积节点）＋偏置/定点缩放/ReLU，PS执行余网", "pl3": "PL前三层卷积＋偏置/定点缩放/ReLU，PS执行余网", "cpu": "纯PS FP32"}[BACKEND]
        print(f"[请求 {request_id}][2/4] 开始 {path_name}；图片统一预处理为320×320", flush=True)
        try:
            process = subprocess.run(command, cwd=ROOT, capture_output=True,
                                     text=True, encoding="utf-8", timeout=90)
            if process.returncode:
                error = process.stderr.strip() or "Inference failed"
                print(f"[请求 {request_id}][失败] {error}", flush=True)
                if any(text in error for text in ("Unsupported or corrupt image", "Image decode failed", "Image exceeds")):
                    status = 400
                elif "NCNN load failed" in error or "Missing or unreadable input" in error:
                    status = 503
                else:
                    status = 500
                self.reply(status, {"error": error, "request_id": request_id})
                return
            result_path = next(line.split("=", 1)[1] for line in process.stdout.splitlines()
                               if line.startswith("RESULT_DIR="))
            result_dir = Path(result_path)
            detections = json.loads((result_dir / "detections.json").read_text(encoding="utf-8"))
            report = json.loads((result_dir / "report.json").read_text(encoding="utf-8"))
            validate_backend_report(report, BACKEND)
            payload = build_response(detections, report["timing_ms"]["inference_mean"], report["original_wh"])
            payload.update({"len": len(detections), "request_id": request_id,
                            "result_dir": result_dir.relative_to(ROOT).as_posix(), **backend_description(BACKEND)})
            for line in format_stage_lines(request_id, report):
                print(line, flush=True)
            for line in format_result_lines(request_id, detections, payload["inference_ms"]):
                print(line, flush=True)
            if self.reply(200, payload):
                print(f"[请求 {request_id}][4/4] 响应已写回本次 HTTP 连接，对端：{peer_ip}；"
                      f"保存位置：{payload['result_dir']}", flush=True)
        except subprocess.TimeoutExpired:
            self.reply(504, {"error": "Inference timeout", "request_id": request_id})
        except (OSError, ValueError, TypeError, KeyError, StopIteration) as error:
            print(f"[请求 {request_id}][失败] {error}", flush=True)
            self.reply(500, {"error": str(error), "request_id": request_id})


def main():
    global BACKEND
    settings = read_network_config()
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=settings["LISTEN_HOST"])
    parser.add_argument("--port", type=int, default=int(settings["PORT"]))
    parser.add_argument("--backend", choices=("cpu", "pl3", "pl21", "pl30"), default="pl30")
    parser.add_argument("--check", action="store_true", help="Read-only hardware/model preflight; no DMA")
    parser.add_argument("--check-hardware", action="store_true", help="Read-only assets/bit/DT check before loading the DMA client")
    parser.add_argument("--predict", type=Path, help="Run one image using the selected backend")
    args = parser.parse_args()
    BACKEND = args.backend
    preflight(BACKEND, args.check_hardware)
    if args.check or args.check_hardware:
        print(f"[检查通过] 后端={backend_description(BACKEND)['backend']}；未发起DMA", flush=True)
        return
    if args.predict:
        raise SystemExit(subprocess.call(inference_command(args.predict.resolve()), cwd=ROOT))

    def stop(signum, frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    # One request at a time keeps PS load and memory bounded on the 7020.
    with HTTPServer((args.host, args.port), Handler) as server:
        print(f"[就绪] http://{args.host}:{args.port}/predict；字段 image_file；后端 {backend_description(BACKEND)['backend']}", flush=True)
        path = {"pl30": "卷积0～30（31节点）连续在PL执行，中间特征片上交接；长期旁路与30出口回PS，其余网络由PS执行", "pl21": "卷积0～21由PL执行，分为0～6/7～11/12～21三个驻留任务，其余网络由PS执行", "pl3": "前三层由PL执行，其余网络由PS执行", "cpu": "纯PS FP32"}[BACKEND]
        print(f"[说明] {path}；结果在原HTTP连接返回；启动不回放历史推理", flush=True)
        try:
            server.serve_forever()
        except (KeyboardInterrupt, SystemExit):
            print("[停止] HTTP 推理服务已退出", flush=True)


if __name__ == "__main__":
    main()
