#!/bin/sh
# PL convrelu_0..30 + fused ReLU; remaining network runs on PS.
# Requires matched bit/DT. Loads the verified DMA client if absent; no PL reconfiguration or CPU fallback.
set -eu

CALLER_DIR=$(pwd)
PKG_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NETWORK_CONFIG="$PKG_DIR/network.conf"
. "$NETWORK_CONFIG"
LOG_DIR="$PKG_DIR/logs"
PID_FILE="$LOG_DIR/server.pid"
LOG_FILE="$LOG_DIR/server.log"

is_running() {
    [ -f "$PID_FILE" ] || return 1
    pid=$(cat "$PID_FILE")
    kill -0 "$pid" 2>/dev/null || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\000' ' ' < "/proc/$pid/cmdline" | grep -Fq -- "$PKG_DIR/server.py"
}

check_files() {
    command -v python3 >/dev/null
    for file in model.ncnn.param model.ncnn.bin label_list server.py network.conf pl30_manifest.json; do
        [ -r "$PKG_DIR/$file" ] || { echo "[失败] 缺少 $PKG_DIR/$file" >&2; exit 1; }
    done
    [ -x "$PKG_DIR/yolo26_detect" ] || { echo "[失败] yolo26_detect 不存在或没有执行权限" >&2; exit 1; }
    python3 -B "$PKG_DIR/server.py" --check-hardware
    if [ ! -e /dev/y26_dma_loopback ]; then
        echo "[准备] 加载已校验的512 KiB DMA客户端，申请双向缓冲区"
        /sbin/insmod "$PKG_DIR/pl30/y26_dma_client.ko"
    fi
    python3 -B "$PKG_DIR/server.py" --check
}

start_service() {
    check_files
    if is_running; then
        health_host="$LISTEN_HOST"
        if [ "$health_host" = "0.0.0.0" ]; then health_host=127.0.0.1; fi
        python3 -c "import json,urllib.request; r=json.load(urllib.request.urlopen('http://$health_host:$PORT/health',timeout=2)); assert r['backend']=='ncnn_pl30' and r['pl_acceleration'] and len(r['accelerated_layers'])==31" || {
            echo "[失败] 已运行的服务不是PL卷积0～30版本；请执行本脚本 restart" >&2; return 1;
        }
        echo "[就绪] PL卷积0～30服务已运行，PID=$(cat "$PID_FILE")，端口 $PORT"
        return
    fi
    mkdir -p "$LOG_DIR" "$PKG_DIR/InferenceResult"
    echo "[1/3] 检查完成：320输入、5类；PL卷积0～30（31节点）连续片上交接＋偏置/定点缩放/ReLU→INT8；PS余网FP32"
    nohup python3 -u "$PKG_DIR/server.py" --host "$LISTEN_HOST" --port "$PORT" >> "$LOG_FILE" 2>&1 &
    echo "$!" > "$PID_FILE"
    echo "[2/3] 已启动 HTTP 进程，等待端口就绪"
    health_host="$LISTEN_HOST"
    if [ "$health_host" = "0.0.0.0" ]; then health_host=127.0.0.1; fi
    attempt=0
    while [ "$attempt" -lt 10 ]; do
        if ! is_running; then
            tail -n 15 "$LOG_FILE"
            echo "[失败] 服务启动失败，请检查日志" >&2
            return 1
        fi
        if python3 -c "import json,urllib.request; r=json.load(urllib.request.urlopen('http://$health_host:$PORT/health',timeout=1)); assert r['backend']=='ncnn_pl30' and r['pl_acceleration'] and len(r['accelerated_layers'])==31" 2>/dev/null; then
            echo "[3/3] 服务就绪：http://$BOARD_IP:$PORT/predict，图片字段 image_file"
            echo "[通信] 配置上位机：$UPPER_IP；结果随本次 HTTP 请求连接返回，不另行推送"
            return
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo "[失败] 等待服务就绪超时，日志：$LOG_FILE" >&2
    return 1
}

stop_service() {
    if is_running; then
        kill "$(cat "$PID_FILE")"
        attempt=0
        while is_running && [ "$attempt" -lt 10 ]; do
            sleep 1
            attempt=$((attempt + 1))
        done
        if is_running; then echo "[失败] 服务尚未停止" >&2; return 1; fi
    fi
    rm -f "$PID_FILE"
    echo "[停止] HTTP 服务已停止"
}

monitor_service() {
    echo "[监视] Ctrl+C 退出日志监视；后台推理服务继续运行"
    echo "[等待] 仅显示从现在起的新日志，请发送图片……"
    tail -n 0 -f "$LOG_FILE"
}

case "${1:-run}" in
    run) start_service; monitor_service ;;
    deploy|start) start_service ;;
    restart) stop_service; start_service ;;
    stop) stop_service ;;
    status)
        echo "[网络配置] 板端 $BOARD_IP:$PORT；上位机核对 $UPPER_IP"
        if is_running; then echo "[运行中] PID=$(cat "$PID_FILE")，端口 $PORT"; else echo "[未运行]"; fi
        if [ -f "$LOG_FILE" ]; then tail -n 10 "$LOG_FILE"; fi
        ;;
    monitor) monitor_service ;;
    config) cat "$NETWORK_CONFIG" ;;
    set-upper-ip)
        [ "$#" -eq 2 ] || { echo "用法：sh $0 set-upper-ip 上位机IPv4" >&2; exit 2; }
        python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$2" 2>/dev/null || {
            echo "[失败] 无效的IPv4地址：$2" >&2; exit 2;
        }
        sed -i "s/^UPPER_IP=.*/UPPER_IP=$2/" "$NETWORK_CONFIG"
        echo "[配置完成] 上位机核对IP：$2；立即生效，无需修改代码或重启服务"
        echo "[说明] HTTP结果仍返回实际发图客户端；此配置不修改对方网卡IP"
        ;;
    predict)
        check_files
        image="${2:-$PKG_DIR/205.jpg}"
        case "$image" in /*) ;; *) image="$CALLER_DIR/$image" ;; esac
        cd "$PKG_DIR"
        exec python3 -u server.py --predict "$image"
        ;;
    help|-h|--help)
        echo "用法：sh $PKG_DIR/Zynq7020.sh [run|deploy|start|restart|stop|status|monitor|config|set-upper-ip IP|predict [图片]]"
        echo "无参数：启动HTTP服务并监视日志；start/deploy：后台启动后返回终端。"
        ;;
    *) echo "[失败] 未知命令：$1" >&2; exit 2 ;;
esac
