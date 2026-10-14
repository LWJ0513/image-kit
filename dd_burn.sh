#!/usr/bin/env bash
#
# dd_burn.sh - burn.sh 와 같은 일을 하되 장치마다 dd 를 따로 띄운다.
#
#   sudo ./dd_burn.sh [옵션] <이미지> <장치...>
#
#   sudo ./dd_burn.sh mycobot280_rdk_x5.img sda sdb sdc sdd sde sdf
#   sudo ./dd_burn.sh -f mycobot280_rdk_x5.img sdg
#
# burn.sh(mbuffer 하나에 출력 여러 개)는 가장 느린 카드 속도로 전체가 묶인다.
# 여기서는 장치별로 굽기 -> 검증을 독립 수행하므로 빠른 카드는 먼저 PASS 가 뜨고,
# PASS 가 뜬 카드는 나머지가 끝나기 전에 뽑아도 된다.
# 전부 끝나는 시간은 가장 느린 카드가 정한다 (단축되지 않음).
#
# 검증 모드:
#          -n, --no-verify  검증 생략. 굽기만 하고 끝낸다.
#   (기본) -q, --quick   샘플 검증. 앞/뒤 256MiB + 균등 분포 64개 x 16MiB = 1.5GiB.
#          -f, --full    전체 비교. 장치당 이미지 전체를 읽는다.
#
set -euo pipefail

## --- 샘플 검증 파라미터 (burn.sh 와 동일) ---
Q_EDGE=$((256 * 1024 * 1024))
Q_CHUNKS=64
Q_CHUNK=$((16 * 1024 * 1024))
ALIGN=$((4 * 1024 * 1024))

INTERVAL=2 ## 진행 표시 갱신 주기(초)

## --- 화면 표시 ---
if [ -t 1 ]; then
	TTY=1
	B=$'\033[1m' R=$'\033[1;31m' G=$'\033[1;32m' Y=$'\033[1;33m' N=$'\033[0m'
else
	TTY=0
	B='' R='' G='' Y='' N=''
fi

section() {
	echo
	echo "${B}════════════════ $1 ════════════════${N}"
	echo
}

fmt_dur() {
	local s=$1
	if [ "$s" -ge 3600 ]; then
		printf '%d시간 %d분 %d초' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
	elif [ "$s" -ge 60 ]; then
		printf '%d분 %d초' $((s / 60)) $((s % 60))
	else
		printf '%d초' "$s"
	fi
}

fmt_size() {
	numfmt --to=iec-i --suffix=B --format=%.1f "$1"
}

port_of() {
	local l
	for l in /dev/disk/by-path/*-usb-*; do
		[ -e "$l" ] || continue
		[ "$(readlink -f "$l")" = "/dev/$1" ] || continue
		echo "${l##*/}" | sed -n 's/.*-usb-0:\([0-9.]*\):.*/USB포트 \1/p'
		return 0
	done
	return 0
}

VERIFY=quick
ARGS=()
for a in "$@"; do
	case "$a" in
	-q | --quick) VERIFY=quick ;;
	-f | --full) VERIFY=full ;;
	-n | --no-verify) VERIFY=none ;;
	-h | --help)
		sed -n '3,${/^#/!q; s/^# \{0,1\}//p;}' "$0"
		exit 0
		;;
	-*)
		echo "unknown option: $a" >&2
		exit 2
		;;
	*) ARGS+=("$a") ;;
	esac
done
set -- "${ARGS[@]}"

[ "$(id -u)" -eq 0 ] || {
	echo "sudo 로 실행하세요."
	exit 1
}

[ $# -ge 2 ] || {
	echo "사용법: sudo $0 [-q|-f|-n] <이미지> <장치...>"
	exit 1
}

IMAGE="$1"
shift
[ -r "$IMAGE" ] || {
	echo "이미지를 읽을 수 없음: $IMAGE"
	exit 1
}

SZ=$(stat -c %s "$IMAGE")
## set -e + pipefail 이라 || true 가 없으면 판별 실패 시 메시지 없이 종료된다
ROOT=$(lsblk -no PKNAME "$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null |
	head -1 | tr -d ' ' || true)
[ -n "$ROOT" ] || echo "${Y}참고: 시스템 디스크를 판별하지 못했습니다. USB 검사로만 걸러집니다.${N}" >&2

DEVS=()
for d in "$@"; do
	[ -n "$d" ] || {
		echo "빈 장치 이름이 인자로 들어왔습니다."
		exit 1
	}
	DEVS+=("${d#/dev/}")
done

# --- 안전 검사 ---
declare -A PORT DDFLAG
for d in "${DEVS[@]}"; do
	[ -b "/dev/$d" ] || {
		echo "없는 장치: $d"
		exit 1
	}
	[ "$d" != "$ROOT" ] || {
		echo "시스템 디스크: $d"
		exit 1
	}
	[ "$(lsblk -dno TRAN /dev/$d | tr -d ' ')" = usb ] || {
		echo "USB 아님: $d"
		exit 1
	}
	[ "$(blockdev --getsize64 /dev/$d)" -ge "$SZ" ] || {
		echo "용량 부족: $d"
		exit 1
	}
	PORT[$d]=$(port_of "$d")
	## O_DIRECT 는 마지막 write 도 섹터 크기 배수여야 해서, 아니면 일반 쓰기 + fsync 로 대체
	if [ $((SZ % $(blockdev --getss /dev/$d))) -eq 0 ]; then
		DDFLAG[$d]="oflag=direct conv=fsync"
	else
		DDFLAG[$d]="conv=fsync"
		echo "${Y}참고: $d 이미지 크기가 섹터 배수가 아니라 direct I/O 없이 씁니다.${N}" >&2
	fi
done

echo
echo "${B}═══════════════════════════════════════════════════════════${N}"
echo "  이미지 : $IMAGE ($(numfmt --to=iec-i --suffix=B "$SZ"))"
echo "  검증   : $VERIFY"
echo "  방식   : 장치별 dd 독립 실행"
echo "───────────────────────────────────────────────────────────"
echo "  ${Y}아래 ${#DEVS[@]}개 장치에 지금 들어있는 내용이 전부 사라집니다."
echo "  이미지로 통째로 덮어쓰며, 되돌릴 수 없습니다.${N}"
echo
for d in "${DEVS[@]}"; do
	printf '    %-10s %8s  %-18s %s\n' \
		"/dev/$d" \
		"$(lsblk -dno SIZE "/dev/$d" | tr -d ' ')" \
		"$(lsblk -dno MODEL "/dev/$d" | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')" \
		"${PORT[$d]}"
done
echo "${B}═══════════════════════════════════════════════════════════${N}"
echo
read -r -p "  작업을 진행하시겠습니까? [Y/N]: " a
case "$a" in
y | Y | yes | YES) ;;
*)
	echo
	echo "취소되었습니다."
	exit 1
	;;
esac

# --- 마운트 해제 ---
for d in "${DEVS[@]}"; do
	for p in $(lsblk -rno NAME "/dev/$d" | tail -n +2); do
		umount "/dev/$p" 2>/dev/null || true
	done
done
sync

## 비교할 구간 목록 ("offset:length")
SAMPLES=()
VTOTAL=$SZ
if [ "$VERIFY" = quick ]; then
	SAMPLES+=("0:$Q_EDGE")
	span=$((SZ - 2 * Q_EDGE))
	if [ "$span" -gt "$((Q_CHUNK * Q_CHUNKS))" ]; then
		step=$((span / (Q_CHUNKS + 1)))
		for i in $(seq 1 "$Q_CHUNKS"); do
			off=$((Q_EDGE + step * i))
			off=$((off / ALIGN * ALIGN))
			SAMPLES+=("$off:$Q_CHUNK")
		done
	fi
	SAMPLES+=("$((SZ - Q_EDGE)):$Q_EDGE")
	VTOTAL=0
	for spec in "${SAMPLES[@]}"; do VTOTAL=$((VTOTAL + ${spec##*:})); done
fi

verify_dev() {
	local d=$1 spec off len
	if [ "$VERIFY" = full ]; then
		cmp -s -n "$SZ" "$IMAGE" "/dev/$d"
		return
	fi
	for spec in "${SAMPLES[@]}"; do
		off=${spec%%:*}
		len=${spec##*:}
		cmp -s -i "$off:$off" -n "$len" "$IMAGE" "/dev/$d" || return 1
	done
}

## /sys/block/<dev>/stat 의 섹터 카운터(512B 단위). 장치 진행률을 dd 출력 파싱 없이 얻기 위함.
## $1=dev, $2=읽음|쓰기 -> 누적 섹터 수
sectors() {
	local rs ws
	read -r _ _ rs _ _ _ ws _ <"/sys/block/$1/stat"
	if [ "$2" = read ]; then echo "$rs"; else echo "$ws"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

## 상태 파일은 mv 로 교체해서 표시 루프가 반쯤 쓰인 내용을 읽지 않게 한다
set_state() {
	echo "$2" >"$WORK/$1.state.tmp"
	mv "$WORK/$1.state.tmp" "$WORK/$1.state"
}

## 장치 하나: 굽기 -> 검증. 결과는 상태 파일로만 알린다.
## 상태: write | verify <읽기섹터기준> | pass <초> | done <초> | fail-write <초> | fail-verify <초>
worker() {
	local d=$1 t0
	t0=$(date +%s)
	set_state "$d" write
	# shellcheck disable=SC2086
	if ! dd if="$IMAGE" of="/dev/$d" bs=4M ${DDFLAG[$d]} status=none 2>"$WORK/$d.err"; then
		set_state "$d" "fail-write $(($(date +%s) - t0))"
		return
	fi
	echo "$(($(date +%s) - t0))" >"$WORK/$d.wsec"
	if [ "$VERIFY" = none ]; then
		set_state "$d" "done $(($(date +%s) - t0))"
		return
	fi
	## 일반 쓰기로 대체된 장치는 page cache 에서 읽히면 검증 의미가 없어서 비운다
	blockdev --flushbufs "/dev/$d" 2>/dev/null || true
	set_state "$d" "verify $(sectors "$d" read)"
	if verify_dev "$d"; then
		set_state "$d" "pass $(($(date +%s) - t0))"
	else
		set_state "$d" "fail-verify $(($(date +%s) - t0))"
	fi
}

declare -A PID W0 PREV
for d in "${DEVS[@]}"; do
	W0[$d]=$(sectors "$d" write)
	PREV[$d]=0
done

## 비대화형 셸의 백그라운드 작업은 SIGINT 를 무시하므로, Ctrl-C 시 dd/cmp 를 직접 끝낸다
abort() {
	trap - INT TERM
	for p in "${PID[@]}"; do
		pkill -TERM -P "$p" 2>/dev/null || true
		kill "$p" 2>/dev/null || true
	done
	wait 2>/dev/null || true
	echo
	echo "${R}중단됨. 진행 중이던 장치는 이미지가 덜 쓰인 상태입니다.${N}"
	exit 130
}
trap abort INT TERM

section "Flashing — ${#DEVS[@]}개 독립 실행"
t0=$SECONDS
for d in "${DEVS[@]}"; do
	worker "$d" &
	PID[$d]=$!
done

drawn=0
last_print=-999
tprev=$SECONDS
while :; do
	sleep "$INTERVAL"
	now=$SECONDS
	dt=$((now - tprev))
	[ "$dt" -gt 0 ] || dt=1
	tprev=$now
	busy=0
	LINES_OUT=()
	for d in "${DEVS[@]}"; do
		st=$(cat "$WORK/$d.state" 2>/dev/null || echo write)
		kind=${st%% *}
		arg=${st#* }
		## 워커가 상태를 못 남기고 죽은 경우 무한 대기를 막는다
		case "$kind" in
		write | verify)
			if ! kill -0 "${PID[$d]}" 2>/dev/null; then
				## 방금 정상 종료했을 수 있으니 한 번 더 읽는다
				st=$(cat "$WORK/$d.state" 2>/dev/null || echo write)
				kind=${st%% *}
				arg=${st#* }
				case "$kind" in write | verify)
					kind=fail-write
					arg=$((now - t0))
					set_state "$d" "fail-write $arg"
					;;
				esac
			fi
			;;
		esac
		case "$kind" in
		write)
			busy=1
			w=$((($(sectors "$d" write) - ${W0[$d]}) * 512))
			[ "$w" -le "$SZ" ] || w=$SZ
			rate=$(((w - ${PREV[$d]}) / dt))
			PREV[$d]=$w
			if [ "$rate" -gt 0 ]; then
				eta="남은 $(fmt_dur $(((SZ - w) / rate)))"
			else
				eta=""
			fi
			msg=$(printf '굽는 중 %3d%%  %s / %s  %s/s  %s' \
				$((w * 100 / SZ)) "$(fmt_size "$w")" "$(fmt_size "$SZ")" \
				"$(fmt_size "$rate")" "$eta")
			;;
		verify)
			busy=1
			r=$((($(sectors "$d" read) - arg) * 512))
			[ "$r" -le "$VTOTAL" ] || r=$VTOTAL
			msg=$(printf '검증 중 %3d%%  (%s)' $((r * 100 / VTOTAL)) "$VERIFY")
			;;
		pass) msg="${G}PASS${N}  $(fmt_dur "$arg")" ;;
		done) msg="${G}완료${N}  $(fmt_dur "$arg") (검증 생략)" ;;
		fail-write) msg="${R}FAIL${N}  쓰기 실패 $(head -c 120 "$WORK/$d.err" 2>/dev/null | tr '\n' ' ')" ;;
		fail-verify) msg="${R}FAIL${N}  이미지와 다릅니다" ;;
		*) msg="$st" ;;
		esac
		LINES_OUT+=("$(printf '    %-6s %-16s %s' "$d" "${PORT[$d]}" "$msg")")
	done

	if [ "$TTY" -eq 1 ]; then
		## 같은 자리에 다시 그린다
		[ "$drawn" -eq 0 ] || printf '\033[%dA' "${#LINES_OUT[@]}"
		for l in "${LINES_OUT[@]}"; do printf '%s\033[K\n' "$l"; done
		drawn=1
	elif [ "$busy" -eq 0 ] || [ $((now - last_print)) -ge 30 ]; then
		printf '%s\n' "${LINES_OUT[@]}"
		echo
		last_print=$now
	fi
	[ "$busy" -eq 1 ] || break
done
wait 2>/dev/null || true
trap - INT TERM
TOTAL_SEC=$((SECONDS - t0))

# --- 결과 ---
section "결과"
FAILED=()
for d in "${DEVS[@]}"; do
	st=$(cat "$WORK/$d.state" 2>/dev/null || echo fail-write)
	case "${st%% *}" in
	pass | done) ;;
	*) FAILED+=("$d") ;;
	esac
	if [ -s "$WORK/$d.wsec" ]; then
		ws=$(cat "$WORK/$d.wsec")
		[ "$ws" -gt 0 ] || ws=1
		printf '    %-6s 쓰기 %s  평균 %s/s\n' "$d" "$(fmt_dur "$ws")" "$(fmt_size $((SZ / ws)))"
	fi
done
echo
printf '  전체 소요 : %s\n' "$(fmt_dur "$TOTAL_SEC")"
printf '  결과      : PASS %d개 / FAIL %d개\n' \
	"$((${#DEVS[@]} - ${#FAILED[@]}))" "${#FAILED[@]}"
if [ "${#FAILED[@]}" -eq 0 ]; then
	echo
	echo "  ${G}전체 통과 — ${#DEVS[@]}개 모두 완료.${N}"
	echo
	exit 0
fi
printf '  불일치    : %s\n' "${FAILED[*]}"
echo
echo "  ${R}위 장치는 다시 flashing 해야 합니다.${N}"
echo
exit 1
