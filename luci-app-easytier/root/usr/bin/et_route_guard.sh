#!/bin/sh
# et_route_guard.sh — EasyTier 代理网段「内核路由」对账守卫
#
# 背景：EasyTier 2.7.0 的 proxy_cidrs 路由安装是纯事件驱动的增量 diff，
#       不做周期性对账；install 失败时只打 trace 级日志（本机 console-log-level=off 完全看不到）。
#       一旦内核侧路由被清掉（或某次 add 失败），core 的内存路由表仍然显示正常（Web 界面照旧），
#       但内核永远装不回来，只有重启进程才会恢复。
#       本脚本正是补上「对账」这一环：只用 easytier-cli 拿 core 认为该有的网段，
#       与内核 tun0 上的路由比对，缺哪条补哪条 —— 不重启进程、不中断隧道。
#
# 数据来源：easytier-cli -o json -p 127.0.0.1:15888 route
#   （15888 是 EasyTier 的 RPC portal，自定义协议，不是 HTTP，没有 /api/route/ 这种 REST 接口）
#
# 用法：
#   sh et_route_guard.sh          # 正常执行一次
#   DRYRUN=1 sh et_route_guard.sh # 只打印将要做什么，不落地
# 定时：由 luci-app-easytier 的 postinst 自动注册 crontab（每分钟一次），
#       脚本幂等：无异常时不产生动作，只在状态变化时落一行快照。

PATH=/usr/sbin:/usr/bin:/sbin:/bin
TUN="${TUN:-tun0}"                     # EasyTier 虚拟网卡名
RPC="${RPC:-127.0.0.1:15888}"          # core 的 RPC portal
METRIC="${METRIC:-65535}"              # 与 EasyTier 自己安装路由时的 metric 保持一致
LOG="${LOG:-/var/log/et_route_guard.log}"
STATE="${STATE:-/tmp/et_route_guard.state}"   # 记录上次观测到的内核状态签名（用于抓触发时刻）
MAXLOG=300
DRYRUN="${DRYRUN:-0}"

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG"
	n=$(wc -l <"$LOG" 2>/dev/null)
	if [ "${n:-0}" -gt "$MAXLOG" ]; then
		tail -n "$MAXLOG" "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
	fi
}

# ---- 前置检查：tun 未就绪 / cli 不可用时静默跳过，绝不误判 ----
ip link show "$TUN" >/dev/null 2>&1 || exit 0
command -v easytier-cli >/dev/null 2>&1 || { log "ERR easytier-cli 不存在"; exit 1; }

json=$(easytier-cli -o json -p "$RPC" route 2>/dev/null)
if [ -z "$json" ]; then
	log "WARN easytier-cli 取不到路由（RPC $RPC 不可用），本轮跳过"
	exit 0
fi

# ---- core 认为应当出现在 tun0 上的网段：所有非本机节点的 proxy_cidrs ----
# 本机条目 next_hop_hostname 为 Local，必须排除：它 advertised 的是自己的 LAN 网段，
# 那条路由本来就在 br-lan 上，往 tun0 上装会把局域网流量劫持进隧道。
expected=$(printf '%s\n' "$json" | awk -F'"' '
	/"ipv4"/                { pc = "" }
	/"proxy_cidrs"/         { pc = $4 }
	/"next_hop_hostname"/   { if ($4 != "Local" && pc != "") print pc }
' | tr ',' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | grep -v '^0\.0\.0\.0/0$' | sort -u)

# 注意：即使 $expected 为空（对端全部离线）也不能提前退出 ——
# 下面的 STATE 快照和 tun 自身网段看护与对端是否在线无关。

# ---- 内核实际挂在 tun0 上的网段 ----
kernel=$(ip route | awk -v d="$TUN" '{
	for (i = 1; i <= NF; i++) if ($i == "dev" && $(i + 1) == d) { print $1; break }
}' | sort -u)

# ---- 状态签名：只在发生变化时落一行快照，用于回溯触发时刻 ----
sig="$(ip -o link show "$TUN" 2>/dev/null | awk '{print $1}')|$(ip -o route show | md5sum | cut -d' ' -f1)"
last=$(cat "$STATE" 2>/dev/null)
if [ "$sig" != "$last" ]; then
	echo "$sig" >"$STATE"
	log "STATE ifindex=$(ip -o link show "$TUN" 2>/dev/null | awk '{print $1}') route=[$(ip route | tr '\n' ';')]"
fi

# ---- 先补齐 tun 自身网段（内核本该自动生成的 proto kernel 前缀路由）----
# 这条丢了不会有明显业务告警：走代理网段（LAN→LAN）照样通，但本机主动访问其它节点的
# 虚拟 IP 会落到默认路由走出 LAN —— 实测此时 ping 对端虚拟 IP 100% 丢包。
tunaddr=$(ip -o addr show "$TUN" 2>/dev/null | awk '$3 == "inet" { print $4; exit }')
if [ -n "$tunaddr" ]; then
	tunip=${tunaddr%/*}
	tunnet=$(echo "$tunaddr" | awk -F'[./]' '{
		p = $5 + 0
		n = (($1 * 256 + $2) * 256 + $3) * 256 + $4
		s = 2 ^ (32 - p)
		n = int(n / s) * s
		printf "%d.%d.%d.%d/%d", int(n / 16777216) % 256, int(n / 65536) % 256, int(n / 256) % 256, n % 256, p
	}')
	if ! ip route | awk -v n="$tunnet" '$1 == n { found = 1 } END { exit !found }'; then
		if [ "$DRYRUN" = "1" ]; then
			log "DRYRUN would add: ip route add $tunnet dev $TUN scope link src $tunip"
		else
			out=$(ip route add "$tunnet" dev "$TUN" scope link src "$tunip" 2>&1)
			if [ $? -eq 0 ]; then
				log "FIX 内核缺失 tun 自身网段 $tunnet，已补路由 dev $TUN src $tunip"
			else
				log "ERR 补 tun 网段路由失败 $tunnet: $out"
			fi
		fi
	fi
fi

# ---- 逐条对账：只补缺失，绝不删除 ----
missing=0
for cidr in $expected; do
	echo "$kernel" | grep -qx "$cidr" && continue
	missing=$((missing + 1))

	# 同网段已由别的接口承载（例如与本机 LAN 重叠）→ 不抢，只记录
	conflict=$(ip route | awk -v c="$cidr" -v d="$TUN" '{
		if ($1 != c) next
		for (i = 1; i <= NF; i++) if ($i == "dev" && $(i + 1) != d) { print; exit }
	}')
	if [ -n "$conflict" ]; then
		log "SKIP $cidr 已由其它接口承载（$conflict），不处理"
		continue
	fi

	if [ "$DRYRUN" = "1" ]; then
		log "DRYRUN would add: ip route add $cidr dev $TUN metric $METRIC"
		continue
	fi

	out=$(ip route add "$cidr" dev "$TUN" metric "$METRIC" 2>&1)
	if [ $? -eq 0 ]; then
		log "FIX 内核缺失 $cidr，已补路由 dev $TUN metric $METRIC"
	else
		log "ERR 补路由失败 $cidr: $out"
	fi
done

# 只有多网段同时消失才值得写一条汇总（单条已有 FIX 明细）
[ "$missing" -gt 1 ] && log "ANOMALY 本轮共发现 $missing 条网段缺失（core 侧仍认为存在，内核侧已丢失）"

exit 0
