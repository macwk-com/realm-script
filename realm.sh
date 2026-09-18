#!/usr/bin/env bash
# Realm Manager — https://github.com/macwk-com/realm-script
# Files are kept compatible with the original /root/realm installation.
BASE_DIR=/root/realm
CONFIG_PATH=/root/.realm/config.toml
UNIT_PATH=/etc/systemd/system/realm.service
BACKUP_ROOT=/root/.realm/backups
LOCK_PATH=/run/lock/realm-manager.lock
SCRIPT_REPO=macwk-com/realm-script
PYTHON=${PYTHON:-python3}
SELF_PATH=$(readlink -f "${BASH_SOURCE[0]}")
SHORTCUT_PATH=/usr/local/bin/realmctl
LEGACY_SCRIPT=/root/realm.sh

error() { printf '\n错误：%s\n' "$*" >&2; return 1; }
# Prompt with line editing (arrow keys work) and trim surrounding spaces. Returns 1 on EOF.
ask() {
    local __value
    IFS= read -e -r -p "$2" __value || return 1
    __value=${__value#"${__value%%[![:space:]]*}"}
    __value=${__value%"${__value##*[![:space:]]}"}
    printf -v "$1" '%s' "$__value"
}
# confirm 问题 [y|n]：y/yes/是 表示同意，回车取默认值。
confirm() {
    local reply default=${2:-n} hint='[y/N]'
    [[ $default == n ]] || hint='[Y/n]'
    ask reply "$1 $hint " || return 1
    reply=${reply:-$default}
    [[ ${reply,,} == y || ${reply,,} == yes || $reply == 是 ]]
}
usage() {
    cat <<'HELP'
用法：
  bash realm.sh                     彩色菜单
  bash realm.sh list                查看规则
  bash realm.sh -l IP:端口 -r 目标:端口   添加规则（仅保存）
  bash realm.sh add IP:端口 目标:端口 [--apply]
  bash realm.sh delete 序号或范围 [--apply]
  bash realm.sh install | update | start | stop | restart | status
  bash realm.sh shortcut             安装 realmctl 快捷命令
IPv6 请写为 [2001:db8::1]:443。--apply 会尝试重启，失败则恢复配置。
HELP
}
check_platform() {
    [[ $EUID -eq 0 ]] || { error '请使用 root 或 sudo 运行。'; return 1; }
    [[ $(uname -s) == Linux ]] || { error '只支持 Linux + systemd；不会在 macOS 安装服务。'; return 1; }
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null || { error '需要正在运行的 systemd。'; return 1; }
}
# Install only what is missing; Rocky/Alma already ship curl-minimal, which conflicts with curl.
check_dependencies() {
    local packages=() cmd
    command -v curl >/dev/null || packages+=(curl ca-certificates)
    command -v python3 >/dev/null || packages+=(python3)
    "$PYTHON" -c 'import tomlkit' >/dev/null 2>&1 || packages+=(python3-tomlkit)
    command -v flock >/dev/null || packages+=(util-linux)
    if (( ${#packages[@]} )); then
        printf '安装依赖：%s\n' "${packages[*]}"
        if command -v apt-get >/dev/null; then
            apt-get update && apt-get install -y "${packages[@]}" || return 1
        elif command -v dnf >/dev/null; then
            # Rocky/Alma ship python3-tomlkit in EPEL.
            dnf install -y epel-release >/dev/null 2>&1 || true
            dnf install -y "${packages[@]}" || return 1
        elif command -v yum >/dev/null; then
            yum install -y "${packages[@]}" || return 1
        else
            error "请手动安装：${packages[*]}"; return 1
        fi
    fi
    for cmd in curl flock; do command -v "$cmd" >/dev/null || return 1; done
    "$PYTHON" -c 'import tomlkit' || return 1
}
init_env() {
    mkdir -p "$BASE_DIR" "$(dirname "$CONFIG_PATH")" "$BACKUP_ROOT" || return 1
    chmod 700 "$BACKUP_ROOT" || return 1
}
# A real TOML parser handles numbering and mutations; comments and unrelated tables survive.
config_tool() {
    "$PYTHON" - "$CONFIG_PATH" "$@" <<'PY'
import sys, pathlib, os, tempfile, ipaddress, re
import tomlkit
path, operation, *args = sys.argv[1:]
p=pathlib.Path(path)
def address(value, listening=False):
    if not isinstance(value,str) or not value or re.search(r'[\s\x00-\x1f\x7f]',value):
        raise ValueError('地址不能为空或含空白/控制字符')
    if value.startswith('['):
        m=re.fullmatch(r'\[([^\]]+)\]:([0-9]+)',value)
        if not m: raise ValueError('IPv6 格式应为 [地址]:端口')
        host,port=m.groups(); ip=ipaddress.IPv6Address(host)
    else:
        if value.count(':')!=1: raise ValueError('格式应为 IP或域名:端口，IPv6 必须加方括号')
        host,port=value.rsplit(':',1)
        try: ip=ipaddress.ip_address(host)
        except ValueError:
            if listening: raise ValueError('监听地址必须是 IP')
            host=host.encode('idna').decode('ascii').rstrip('.')
            if len(host)>253 or not host or any(not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?',s) for s in host.split('.')):
                raise ValueError('无效的目标域名')
            ip=None
    if not re.fullmatch(r'[0-9]{1,5}',port) or not 1<=int(port)<=65535: raise ValueError('端口须为 1–65535')
    return ip or host,int(port)
def validate(doc):
    entries=doc.get('endpoints',[])
    if not isinstance(entries,list): raise ValueError('endpoints 必须是 TOML 数组表')
    occupied=[]
    for index,entry in enumerate(entries,1):
        if not isinstance(entry,dict): raise ValueError(f'规则 {index} 格式不正确')
        host,port=address(entry.get('listen'),True)
        address(entry.get('remote'))
        for old,oldport in occupied:
            if port==oldport and (host==old or host.is_unspecified or old.is_unspecified):
                raise ValueError(f'规则 {index} 监听端口存在重复或通配地址冲突')
        occupied.append((host,port))
    return entries
def protocols(doc, entry=None):
    settings={**dict(doc.get('network',{})),**dict((entry or {}).get('network',{}))}
    return [x for x,on in (('tcp',not settings.get('no_tcp',False)),('udp',settings.get('use_udp',False))) if on]
# Rule numbers such as "2", "1-3" or "1,3 5"; returns sorted 1-based indexes.
def selection(spec, count):
    parts=re.split(r'[,，\s]+',re.sub(r'\s*-\s*','-',spec.strip()))
    if not spec.strip() or any(not re.fullmatch(r'[1-9][0-9]*(?:-[1-9][0-9]*)?',x) for x in parts):
        raise ValueError('请输入序号，例如 2、1-3 或 1,3')
    chosen=set()
    for x in parts:
        a,_,b=x.partition('-'); a,b=sorted((int(a),int(b or a)))
        if b>count: raise ValueError(f'没有第 {b} 条规则，现在共 {count} 条')
        chosen.update(range(a,b+1))
    return sorted(chosen)
def save(doc):
    content=tomlkit.dumps(doc)
    validate(tomlkit.parse(content))
    p.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.realm-config-',dir=p.parent)
    try:
        with os.fdopen(fd,'w') as f:
            f.write(content);f.flush();os.fsync(f.fileno())
        os.chmod(tmp, p.stat().st_mode & 0o777 if p.exists() else 0o600)
        os.replace(tmp,p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
try:
    if p.is_symlink(): raise ValueError('配置是软链接，拒绝自动修改')
    if p.exists(): doc=tomlkit.parse(p.read_text())
    else: doc=tomlkit.parse('[network]\nno_tcp = false\nuse_udp = true\n')
    entries=validate(doc)
    if operation=='list':
        print(f"{'序号':<6} {'本地监听':<30} 远程目标")
        for i,e in enumerate(entries,1): print(f"{i:<8} {e['listen']:<34} {e['remote']}")
        if not entries: print('暂无转发规则')
    elif operation=='count': print(len(entries))
    elif operation=='validate':
        if not p.exists(): raise ValueError('配置文件不存在')
    elif operation=='init':
        if not p.exists(): save(doc)
    elif operation=='add':
        if len(args)!=2: raise ValueError('添加需要监听地址和目标地址')
        address(args[0],True);address(args[1])
        if 'endpoints' not in doc: doc['endpoints']=tomlkit.aot()
        entry=tomlkit.table();entry['listen']=args[0];entry['remote']=args[1]
        doc['endpoints'].append(entry);save(doc)
    elif operation=='delete':
        if len(args)!=1: raise ValueError('请输入序号，例如 2、1-3 或 1,3')
        for index in reversed(selection(args[0],len(entries))): del doc['endpoints'][index-1]
        if not doc['endpoints']: del doc['endpoints']
        save(doc)
    elif operation=='show':
        for index in selection(args[0],len(entries)):
            print(f"  {index}. {entries[index-1]['listen']}  →  {entries[index-1]['remote']}")
    elif operation=='check-listen':
        host,port=address(args[0],True)
        for index,entry in enumerate(entries,1):
            old,oldport=address(entry['listen'],True)
            if port==oldport and (host==old or host.is_unspecified or old.is_unspecified):
                raise ValueError(f'和第 {index} 条规则的监听端口 {port} 冲突')
        print(port)
    elif operation=='check-remote': address(args[0])
    elif operation=='listens':
        # Ports Realm should bind, following the global and per-rule [network] switches.
        for entry in entries:
            port=address(entry['listen'],True)[1]
            for proto in protocols(doc,entry): print(port,proto)
    elif operation=='rows':
        for index,entry in enumerate(entries,1):
            port=address(entry['listen'],True)[1]
            print(index,entry['listen'],entry['remote'],port,','.join(protocols(doc,entry)) or '-',sep='\t')
    elif operation=='protocols':
        print(' + '.join(x.upper() for x in protocols(doc)) or '无')
    else: raise ValueError('未知配置操作')
except Exception as e:
    print(f'配置操作失败：{e}',file=sys.stderr);sys.exit(1)
PY
}
# Snapshot manifest names exact files, including absence. Backups never enter the source repository.
snapshot() {
    tx_backup=$(mktemp -d "$BACKUP_ROOT/snapshot-XXXXXXXX") || return 1
    "$PYTHON" - "$tx_backup" "$@" <<'PY'
import sys,pathlib,shutil,json
root=pathlib.Path(sys.argv[1]);items=[]
for n,name in enumerate(sys.argv[2:]):
    p=pathlib.Path(name)
    if p.is_symlink() or (p.exists() and not p.is_file()): raise SystemExit('不覆盖软链接或特殊文件：'+name)
    item={'path':str(p),'exists':p.exists(),'copy':str(n)}
    if p.exists(): shutil.copy2(p,root/str(n))
    items.append(item)
(root/'manifest.json').write_text(json.dumps(items))
PY
    if [[ $? -ne 0 ]]; then
        rm -rf -- "$tx_backup"
        tx_backup=''
        return 1
    fi
}
restore_snapshot() {
    "$PYTHON" - "$1" <<'PY'
import sys,pathlib,shutil,json,tempfile,os
root=pathlib.Path(sys.argv[1])
for item in json.loads((root/'manifest.json').read_text()):
    p=pathlib.Path(item['path'])
    if item['exists']:
        fd,tmp=tempfile.mkstemp(dir=p.parent,prefix='.realm-restore-');os.close(fd)
        try: shutil.copy2(root/item['copy'],tmp);os.replace(tmp,p)
        finally:
            if os.path.exists(tmp):os.unlink(tmp)
    else:
        if p.exists():p.unlink()
PY
}
prune_backups() {
    "$PYTHON" - "$BACKUP_ROOT" "$tx_backup" <<'PY'
import sys,pathlib,shutil
root=pathlib.Path(sys.argv[1]);keep=pathlib.Path(sys.argv[2])
for p in root.glob('snapshot-*'):
    if p!=keep and not p.is_symlink() and p.is_dir() and (p/'manifest.json').is_file():shutil.rmtree(p)
PY
}
# Name of the program listening on a port; $2 is t (TCP) or u (UDP).
port_owner() {
    ss -Hlnp"$2" "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1
}
# Realm stays "active" even when a listener fails to bind, so check every configured port.
wait_listening() {
    local expected missing item port proto owner i
    command -v ss >/dev/null || return 0
    expected=$(config_tool listens) || return 1
    for ((i=0;i<5;i++)); do
        missing=''
        while read -r port proto; do
            [[ -z $port || $(port_owner "$port" "${proto:0:1}") == realm ]] || missing+=" $port/$proto"
        done <<< "$expected"
        [[ -n $missing ]] || return 0
        sleep 1
    done
    printf '\nRealm 在运行，但这些端口没有监听成功，对应的转发不会生效：\n' >&2
    for item in $missing; do
        port=${item%/*}; proto=${item#*/}
        owner=$(port_owner "$port" "${proto:0:1}")
        if [[ -n $owner ]]; then printf '  %s  已被 %s 占用\n' "$item" "$owner" >&2
        else printf '  %s  没有监听，请查看日志（菜单 11）\n' "$item" >&2; fi
    done
    return 1
}
wait_service() {
    local i
    for ((i=0;i<10;i++)); do
        if systemctl is-active --quiet realm.service; then
            sleep 2
            systemctl is-active --quiet realm.service && { wait_listening; return; }
        fi
        sleep 1
    done
    journalctl -u realm.service -n 30 --no-pager >&2 || true
    return 1
}
transaction_end() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ ${tx_committed:-0} == 0 && -n ${tx_backup:-} ]]; then
        printf '\n操作未完成，恢复修改前的文件。备份：%s\n' "$tx_backup" >&2
        if restore_snapshot "$tx_backup"; then
            if [[ ${service_touched:-0} == 1 ]]; then
                systemctl daemon-reload || true
                if [[ ${was_enabled:-0} == 1 ]]; then systemctl enable realm.service || true
                else systemctl disable --quiet realm.service 2>/dev/null || true; fi
                if [[ ${was_active:-0} == 1 ]]; then
                    if ! systemctl restart realm.service || ! wait_service; then
                        printf '原文件已恢复，但服务恢复失败，请查看日志。\n' >&2
                    fi
                else
                    systemctl stop realm.service || true
                fi
            fi
        else
            printf '自动恢复失败，请根据备份人工恢复。\n' >&2
        fi
    fi
    [[ -z ${stage_dir:-} ]] || rm -rf -- "$stage_dir"
    exit "$rc"
}
begin_transaction() {
    tx_committed=0;service_touched=0;was_active=0;was_enabled=0
    systemctl is-active --quiet realm.service && was_active=1
    systemctl is-enabled --quiet realm.service && was_enabled=1
    snapshot "$@" || return 1
    trap transaction_end EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '修改前备份：%s\n' "$tx_backup"
}
commit_transaction() {
    tx_committed=1
    prune_backups || printf '操作成功，但旧备份清理失败，请检查 %s。\n' "$BACKUP_ROOT" >&2
}
# Each operation runs in its own subshell so traps and temporary state cannot leak into the menu.
# Each operation runs in its own subshell so traps and temporary state cannot leak into the menu.
# apply=yes restarts a running service, starts a stopped one, and stops it once no rule is left.
mutate_config() (
    local op=$1 value=$2 apply=$3 extra=${4:-} port owner proto
    init_env || return 1
    if [[ $op == add ]]; then
        port=$(config_tool check-listen "$value") || return 1
        config_tool check-remote "$extra" || return 1
        for proto in t u; do
            owner=$(port_owner "$port" "$proto")
            [[ -z $owner || $owner == realm ]] || { error "本机端口 $port 已被 $owner 使用，请换一个端口。"; return 1; }
        done
    fi
    begin_transaction "$CONFIG_PATH" || return 1
    if [[ $op == add ]]; then config_tool add "$value" "$extra" || return 1
    else config_tool delete "$value" || return 1; fi
    if [[ $apply == yes ]]; then
        [[ -x $BASE_DIR/realm && -f $UNIT_PATH ]] || { error 'Realm 未部署，已恢复配置；可不加 --apply 仅保存。'; return 1; }
        service_touched=1
        if [[ $(config_tool count) == 0 ]]; then
            # Realm refuses to run without endpoints.
            systemctl stop realm.service || return 1
            systemctl disable --quiet realm.service 2>/dev/null || true
            printf '规则已全部删除，Realm 已停止。\n'
        elif (( was_active )); then
            systemctl restart realm.service && wait_service || return 1
            printf '配置已保存，Realm 已重启，所有端口都在正常监听。\n'
        else
            systemctl start realm.service && wait_service || return 1
            systemctl enable --quiet realm.service || return 1
            printf '配置已保存，Realm 已启动并设为开机自启，所有端口都在正常监听。\n'
        fi
    else
        printf '配置已保存，还没有应用到正在运行的服务。\n'
    fi
    commit_transaction
)
# Remind about UFW when it is active and the port has no allow rule of its own.
firewall_hint() {
    local port=$1 status cmd="ufw allow $1"
    printf '别忘了在服务商安全组（云防火墙）放行端口 %s（TCP 和 UDP）。\n' "$port"
    command -v ufw >/dev/null && status=$(ufw status 2>/dev/null) || return 0
    [[ $status == 'Status: active'* ]] || return 0
    grep -Eq "^$port(/(tcp|udp))?[[:space:]]" <<< "$status" && return 0
    command -v vpsfw >/dev/null && cmd="vpsfw ports add $port both"
    printf '本机防火墙 UFW 已启用，但端口 %s 还没放行，外部连不进来。可以执行：\n    %s\n' "$port" "$cmd"
}
fetch() { curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout 15 --max-time 180 --retry 2 "$1" -o "$2"; }
asset_name() {
    case $(uname -m) in
        x86_64|amd64) printf 'realm-x86_64-unknown-linux-gnu.tar.gz\n' ;;
        aarch64|arm64) printf 'realm-aarch64-unknown-linux-gnu.tar.gz\n' ;;
        armv7l|armv7) printf 'realm-armv7-unknown-linux-gnueabihf.tar.gz\n' ;;
        armv6l|arm) printf 'realm-arm-unknown-linux-gnueabihf.tar.gz\n' ;;
        *) error '不支持当前 CPU 架构，请手动安装 Realm。'; return 1 ;;
    esac
}
prepare_release() {
    local asset metadata
    asset=$(asset_name) || return 1
    fetch https://api.github.com/repos/zhboner/realm/releases/latest "$stage_dir/release.json" || return 1
    metadata=$("$PYTHON" - "$stage_dir/release.json" "$asset" <<'PY'
import json,sys,re
r=json.load(open(sys.argv[1]));tag=r.get('tag_name','')
if not re.fullmatch(r'v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?',tag):raise SystemExit('发布版本号无效')
a=next((x for x in r.get('assets',[]) if x.get('name')==sys.argv[2]),None)
if not a:raise SystemExit('本次发布没有适配的安装包：'+sys.argv[2])
u=a.get('browser_download_url','')
if u!=f'https://github.com/zhboner/realm/releases/download/{tag}/{sys.argv[2]}':raise SystemExit('发布地址不符合预期')
print(tag);print(u);print(a.get('digest') or '-')
PY
) || return 1
    release_tag=$(printf '%s\n' "$metadata" | sed -n '1p')
    local url digest
    url=$(printf '%s\n' "$metadata" | sed -n '2p')
    digest=$(printf '%s\n' "$metadata" | sed -n '3p')
    printf '下载 Realm %s\n' "$release_tag"
    fetch "$url" "$stage_dir/realm.tar.gz" || return 1
    "$PYTHON" - "$stage_dir" "$digest" <<'PY'
import sys,pathlib,tarfile,hashlib,shutil
root=pathlib.Path(sys.argv[1]);archive=root/'realm.tar.gz';digest=sys.argv[2]
if digest!='-':
    if not digest.startswith('sha256:') or hashlib.sha256(archive.read_bytes()).hexdigest()!=digest[7:]:raise SystemExit('安装包 SHA256 校验失败')
# Extract only one regular executable, never arbitrary paths or symbolic links.
with tarfile.open(archive,'r:gz') as tar:
    matches=[m for m in tar.getmembers() if pathlib.PurePosixPath(m.name).name=='realm' and m.isfile()]
    if len(matches)!=1 or not 0<matches[0].size<=256*1024*1024:raise SystemExit('安装包内容不符合预期')
    with tar.extractfile(matches[0]) as src,open(root/'realm','wb') as dst:shutil.copyfileobj(src,dst)
(root/'realm').chmod(0o755)
PY
    [[ $? -eq 0 ]] || return 1
    local actual
    actual=$("$stage_dir/realm" --version) || { error '新程序无法运行，原安装保持不变。'; return 1; }
    [[ $actual == *"${release_tag#v}"* ]] || { error '程序版本与发布版本不匹配。'; return 1; }
}
atomic_install() {
    local source=$1 target=$2 mode=$3 tmp
    mkdir -p "$(dirname "$target")" || return 1
    tmp=$(mktemp "$(dirname "$target")/.realm-install-XXXXXXXX") || return 1
    if ! install -m "$mode" "$source" "$tmp" || ! mv -f "$tmp" "$target"; then rm -f "$tmp"; return 1; fi
}
deploy_realm() (
    init_env || return 1
    stage_dir=$(mktemp -d "$BASE_DIR/.download-XXXXXXXX") || return 1
    trap 'rm -rf -- "$stage_dir"' EXIT
    prepare_release || return 1
    # Existing files are only touched after a working executable has been staged.
    begin_transaction "$BASE_DIR/realm" "$CONFIG_PATH" "$UNIT_PATH" || return 1
    config_tool init || return 1
    if [[ ! -f $UNIT_PATH ]]; then
        cat > "$stage_dir/realm.service" <<EOF
[Unit]
Description=Realm relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$BASE_DIR
ExecStart=$BASE_DIR/realm -c $CONFIG_PATH
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        atomic_install "$stage_dir/realm.service" "$UNIT_PATH" 644 || return 1
    fi
    atomic_install "$stage_dir/realm" "$BASE_DIR/realm" 755 || return 1
    service_touched=1
    systemctl daemon-reload || return 1
    if (( was_active )); then
        systemctl restart realm.service && wait_service || return 1
        printf 'Realm %s 已安装，现有配置保留，服务已重启，所有端口都在正常监听。\n' "$release_tag"
    elif [[ $(config_tool count) == 0 ]]; then
        printf 'Realm %s 已安装。下一步：添加转发规则（菜单 3）。\n' "$release_tag"
    else
        printf 'Realm %s 已安装，现有规则保留。服务还没启动，可以选择菜单 5 启动。\n' "$release_tag"
    fi
    commit_transaction
)
update_realm() { [[ -x $BASE_DIR/realm ]] || { error '请先部署 Realm。'; return 1; }; deploy_realm; }
# Realm exits immediately without endpoints, so refuse to start it empty.
require_rules() {
    [[ -x $BASE_DIR/realm && -f $UNIT_PATH ]] || { error 'Realm 还没部署，请先选择菜单 1。'; return 1; }
    config_tool validate || return 1
    [[ $(config_tool count) != 0 ]] || { error '还没有转发规则，请先添加（菜单 3）。'; return 1; }
}
start_service() {
    require_rules || return 1
    systemctl daemon-reload && systemctl start realm.service && wait_service && systemctl enable --quiet realm.service || return 1
    printf 'Realm 已启动并设为开机自启，所有端口都在正常监听。\n'
}
stop_service() {
    [[ -f $UNIT_PATH ]] || { error 'Realm 还没部署。'; return 1; }
    systemctl stop realm.service && systemctl disable --quiet realm.service || return 1
    if systemctl is-active --quiet realm.service; then error '服务仍在运行。'; return 1; fi
    printf 'Realm 已停止，开机自启已禁用。\n'
}
restart_service() {
    require_rules || return 1
    systemctl restart realm.service && wait_service || return 1
    printf 'Realm 已重启，所有端口都在正常监听。\n'
}
uninstall_realm() (
    local candidate cleanup_failed=0
    local targets=("$BASE_DIR/realm" "$UNIT_PATH" "$CONFIG_PATH")
    local scripts=()
    for candidate in "$SELF_PATH" "$SHORTCUT_PATH" "$LEGACY_SCRIPT" "$BASE_DIR/realm.sh"; do
        [[ -f $candidate && ! -L $candidate ]] || continue
        if grep -Fq '# Realm Manager —' "$candidate" ||
           { grep -Fq '欢迎使用Realm一键部署脚本' "$candidate" && grep -Fq 'deploy_realm()' "$candidate"; }; then
            # Deduplicate aliases such as SELF_PATH == SHORTCUT_PATH.
            local already=0 existing
            for existing in ${scripts[@]+"${scripts[@]}"}; do [[ $existing != "$candidate" ]] || already=1; done
            (( already )) || scripts+=("$candidate")
        fi
    done
    targets+=(${scripts[@]+"${scripts[@]}"})
    printf '\n完整卸载将停止转发，并删除：\n'
    printf '  %s\n' "${targets[@]}"
    printf '  %s 中本脚本创建的所有 snapshot-* 备份\n' "$BACKUP_ROOT"
    printf '  %s 中的 Realm 安装包；空目录也会移除。\n' "$BASE_DIR"
    printf '不会清理系统共享日志、依赖包或 UFW 规则；其他程序的文件会保留。\n'
    confirm '确认完整卸载（配置和备份不会保留）？' || return 2
    init_env || return 1
    begin_transaction "${targets[@]}" || return 1
    local enabled=0
    systemctl is-enabled --quiet realm.service && enabled=1
    service_touched=1
    # A missing service is already stopped; real stop failures must preserve all files.
    if systemctl is-active --quiet realm.service || [[ -f $UNIT_PATH ]]; then
        systemctl stop realm.service || return 1
    fi
    if systemctl is-active --quiet realm.service; then error '服务仍在运行，已停止卸载。'; return 1; fi
    if (( enabled )); then systemctl disable realm.service || return 1; fi
    rm -f -- "${targets[@]}" || return 1
    systemctl daemon-reload || return 1
    # Recovery remains possible until service removal and script deletion succeed.
    # Complete uninstall explicitly discards the transaction snapshot afterwards.
    tx_committed=1
    "$PYTHON" - "$BASE_DIR" "$CONFIG_PATH" "$BACKUP_ROOT" <<'PY'
import pathlib,re,shutil,sys
base,config,backups=map(pathlib.Path,sys.argv[1:])
if backups.is_symlink(): raise SystemExit('备份目录是软链接，拒绝清理其内容')
if backups.exists():
    for p in backups.iterdir():
        if p.is_dir() and not p.is_symlink() and re.fullmatch(r'snapshot-[A-Za-z0-9]{8}',p.name) and (p/'manifest.json').is_file():
            shutil.rmtree(p)
if base.exists():
    for p in base.iterdir():
        if p.is_file() and not p.is_symlink() and re.fullmatch(r'realm(?:-v?[0-9]+\.[0-9]+\.[0-9]+)?\.tar\.gz',p.name):
            p.unlink()
# Only prune empty directories. Never recursively delete a mixed-use directory.
for p in (backups, config.parent, base):
    if p.is_dir() and not p.is_symlink():
        if not any(p.iterdir()): p.rmdir()
        else: print(f'保留含其他文件的目录：{p}')
PY
    [[ $? -eq 0 ]] || cleanup_failed=1
    if (( cleanup_failed )); then
        error '程序、服务、配置和脚本已卸载，但部分备份/安装包清理失败，请按上面的路径检查。'
        return 1
    fi
    printf '完整卸载完成：程序、服务、配置、管理脚本和备份已删除。\n'
)
# raw.githubusercontent.com caches main for 5 minutes; resolve the latest commit (cached 60s) instead.
latest_commit() {
    local commit
    commit=$(curl --proto '=https' --connect-timeout 10 --max-time 20 -fsS -H 'Accept: application/vnd.github.sha' \
        "https://api.github.com/repos/$SCRIPT_REPO/commits/main" 2>/dev/null) || commit=''
    if [[ $commit =~ ^[0-9a-f]{40}$ ]]; then printf '%s\n' "$commit"; else printf 'main\n'; fi
}
# Returns 0 after replacing the script, 2 when cancelled.
Update_Shell() (
    [[ -f $SELF_PATH && ! -L $SELF_PATH ]] || { error '请先将脚本下载为普通文件再更新。'; return 1; }
    confirm '从项目官方仓库下载最新版并替换当前脚本？' y || return 2
    local tmp ref copy
    tmp=$(mktemp "$(dirname "$SELF_PATH")/.realm-manager-XXXXXXXX") || return 1
    trap 'rm -f -- "$tmp"' EXIT
    ref=$(latest_commit)
    if [[ $ref == main ]]; then printf '暂时查不到最新提交，改用 main 分支地址（刚推送的更新可能要等 5 分钟）。\n'
    else printf '下载最新提交 %s……\n' "${ref:0:7}"; fi
    fetch "https://raw.githubusercontent.com/$SCRIPT_REPO/$ref/realm.sh" "$tmp" || return 1
    bash -n "$tmp" && grep -Fq '# Realm Manager —' "$tmp" || { error '下载内容未通过脚本检查。'; return 1; }
    init_env || return 1
    snapshot "$SELF_PATH" || return 1
    chmod 755 "$tmp" && mv -f "$tmp" "$SELF_PATH" || return 1
    # Keep the realmctl copy on the same version as the script that was updated.
    for copy in "$SHORTCUT_PATH" "$LEGACY_SCRIPT"; do
        [[ $copy != "$SELF_PATH" && -f $copy && ! -L $copy ]] && grep -Fq '# Realm Manager —' "$copy" || continue
        atomic_install "$SELF_PATH" "$copy" 755 && printf '已同步更新 %s\n' "$copy"
    done
    prune_backups || true
    printf '管理脚本已更新。\n'
)
install_shortcut() {
    [[ -f $SELF_PATH ]] || { error '请先把脚本保存为文件。'; return 1; }
    local dest=$SHORTCUT_PATH
    [[ $SELF_PATH != "$dest" ]] || { printf '快捷命令已安装。\n'; return 0; }
    if [[ -e $dest || -L $dest ]]; then
        [[ -f $dest && ! -L $dest ]] && grep -Fq '# Realm Manager —' "$dest" || { error 'realmctl 已被其他程序占用。'; return 1; }
    fi
    atomic_install "$SELF_PATH" "$dest" 755 || return 1
    printf '以后可输入 realmctl 打开菜单。\n'
}
# Colors only on a real terminal; NO_COLOR turns them off.
set_colors() {
    c_ok='' c_warn='' c_err='' c_dim='' c_head='' c_off=''
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
        c_ok=$'\033[32m' c_warn=$'\033[33m' c_err=$'\033[31m'
        c_dim=$'\033[90m' c_head=$'\033[1;36m' c_off=$'\033[0m'
    fi
}
# Terminal cells: CJK characters take two, ● · → take one.
text_width() {
    local text=${1//[●·→]/.} ascii
    ascii=${text//[! -~]/}
    REPLY=$(( ${#ascii} + (${#text} - ${#ascii}) * 2 ))
}
pad() {
    text_width "$1"
    local padding=$(( $2 - REPLY ))
    (( padding > 0 )) || padding=0
    printf '%s%*s' "$1" "$padding" ''
}
section() { printf '\n  %s%s%s\n' "$c_head" "$1" "$c_off"; }
# The config file changed after the running service started.
config_pending() {
    local started
    started=$(systemctl show realm.service -p ActiveEnterTimestamp --value 2>/dev/null)
    [[ -n $started ]] || return 1
    (( $(stat -c %Y "$CONFIG_PATH" 2>/dev/null || echo 0) > $(date -d "$started" +%s 2>/dev/null || echo 0) ))
}
human_uptime() {
    local s=$1
    if (( s < 60 )); then printf '不到 1 分钟'
    elif (( s < 3600 )); then printf '%s 分钟' $(( s / 60 ))
    elif (( s < 86400 )); then printf '%s 小时' $(( s / 3600 ))
    else printf '%s 天' $(( s / 86400 )); fi
}
# Service summary plus every rule with the state of its listening port.
show_overview() {
    set_colors
    local state color note version active=0 pending=0 started rows count broken=0
    local index listen remote port protos cell cell_color proto owner
    rows=$(config_tool rows) || return 1
    count=0; [[ -z $rows ]] || count=$(wc -l <<< "$rows")
    if [[ ! -x $BASE_DIR/realm || ! -f $UNIT_PATH ]]; then
        state='● 未部署'; color=$c_err; note='选择 1 部署 Realm'
    else
        version=$("$BASE_DIR/realm" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        case $(systemctl is-active realm.service 2>/dev/null) in
            active)
                active=1; state='● 运行中'; color=$c_ok
                started=$(systemctl show realm.service -p ActiveEnterTimestamp --value 2>/dev/null)
                note="${version:-版本未知} · "
                if systemctl is-enabled --quiet realm.service; then note+='开机自启'; else note+='未设开机自启'; fi
                [[ -z $started ]] || note+=" · 已运行 $(human_uptime $(( $(date +%s) - $(date -d "$started" +%s) )))"
                config_pending && pending=1 ;;
            failed) state='● 启动失败'; color=$c_err; note='选择 11 查看日志' ;;
            *)
                state='● 未运行'; color=$c_warn; note="${version:-版本未知}"
                (( count == 0 )) || note+=' · 选择 5 启动' ;;
        esac
    fi
    section '服务状态'
    printf '  %s%s%s%s  %s%s%s\n' "$(pad Realm 10)" "$color" "$(pad "$state" 12)" "$c_off" "$c_dim" "$note" "$c_off"
    printf '  %s%s\n' "$(pad 协议 10)" "$(config_tool protocols)"

    section "转发规则（$count 条）"
    if (( count == 0 )); then
        printf '  %s无，选择 3 添加%s\n\n' "$c_dim" "$c_off"
        return 0
    fi
    printf '  %s%s%s%s状态%s\n' "$c_dim" "$(pad 序号 6)" "$(pad 本机监听 24)" "$(pad 远程目标 28)" "$c_off"
    while IFS=$'\t' read -r index listen remote port protos; do
        if (( ! active )); then
            cell='未运行'; cell_color=$c_dim
        else
            cell='● 监听中'; cell_color=$c_ok
            for proto in ${protos//,/ }; do
                owner=$(port_owner "$port" "${proto:0:1}")
                [[ $owner != realm ]] || continue
                if [[ -n $owner ]]; then cell="● 被 $owner 占用"; cell_color=$c_err; broken=1
                elif (( pending )); then cell='● 重启后生效'; cell_color=$c_warn
                else cell="● ${proto^^} 未监听"; cell_color=$c_err; broken=1; fi
                break
            done
        fi
        printf '  %s%s  %s  %s%s%s\n' "$(pad "$index" 6)" "$(pad "$listen" 22)" "$(pad "$remote" 26)" "$cell_color" "$cell" "$c_off"
    done <<< "$rows"
    (( ! pending && ! broken )) || printf '\n'
    (( ! pending )) || printf '  %s配置有改动还没生效，选择 7 重启。%s\n' "$c_warn" "$c_off"
    (( ! broken )) || printf '  %s有端口没监听成功：被占用的请换端口，其他情况选择 11 查看日志。%s\n' "$c_err" "$c_off"
    printf '\n'
}
run_action() (
    exec 9>"$LOCK_PATH" || return 1
    flock -n 9 || { error '另一个 Realm 管理操作正在运行。'; return 1; }
    "$@"
)
# Ask whether to apply now; sets apply to yes or no depending on the running state.
ask_apply() {
    apply=no
    [[ -x $BASE_DIR/realm && -f $UNIT_PATH ]] || { printf 'Realm 还没部署，规则先保存，部署后启动即可生效（菜单 1）。\n'; return 0; }
    if systemctl is-active --quiet realm.service; then
        if confirm '立即重启 Realm 让改动生效？正在转发的连接会断开一下' y; then apply=yes; fi
    elif [[ $1 == add ]]; then
        if confirm 'Realm 现在没有运行，保存后启动它？' y; then apply=yes; fi
    fi
}
menu_add() {
    local value listen remote port rport owner proto apply msg
    printf '\n添加转发规则：把本机的一个端口转发到远程目标。直接回车返回菜单。\n\n'
    while true; do
        ask value '本机监听端口（如 23456）: ' && [[ -n $value ]] || return 0
        if [[ $value =~ ^[0-9]+$ ]]; then listen="0.0.0.0:$value"; else listen=$value; fi
        port=$(config_tool check-listen "$listen" 2>&1) || { printf '%s\n' "${port#配置操作失败：}"; continue; }
        owner=''
        for proto in t u; do
            owner=$(port_owner "$port" "$proto")
            [[ -z $owner || $owner == realm ]] || break
            owner=''
        done
        [[ -z $owner ]] && break
        printf '端口 %s 已被 %s 使用，请换一个。\n' "$port" "$owner"
    done
    while true; do
        ask value '远程目标（IP 或域名:端口，如 1.2.3.4:443）: ' && [[ -n $value ]] || return 0
        # A bare IPv6 address or a host without a port still needs the remote port.
        if [[ $value != *:* || $value == \[*\] || ( $value == *:*:* && $value != \[* ) ]]; then
            [[ $value == *:* && $value != \[* ]] && value="[$value]"
            ask rport '远程端口: ' && [[ -n $rport ]] || return 0
            value="$value:$rport"
        fi
        remote=$value
        msg=$(config_tool check-remote "$remote" 2>&1) && break
        printf '%s\n' "${msg#配置操作失败：}"
    done
    printf '\n将添加：本机 %s  →  %s\n' "$listen" "$remote"
    ask_apply add
    if run_action mutate_config add "$listen" "$apply" "$remote"; then
        firewall_hint "$port"
    else
        error '添加没有完成，配置没有改动。'
    fi
}
menu_delete() {
    local count value chosen apply
    count=$(config_tool count) || return 0
    (( count > 0 )) || { printf '\n还没有转发规则。\n'; return 0; }
    printf '\n'
    config_tool list
    printf '\n'
    while true; do
        ask value '要删除哪几条？输入序号，如 2、1-3 或 1,3（回车返回）: ' && [[ -n $value ]] || return 0
        chosen=$(config_tool show "$value" 2>&1) && break
        printf '%s\n' "${chosen#配置操作失败：}"
    done
    printf '\n将删除：\n%s\n' "$chosen"
    confirm '确认删除？' || { printf '已取消。\n'; return 0; }
    ask_apply delete
    run_action mutate_config delete "$value" "$apply" || error '删除没有完成，配置没有改动。'
}
menu() {
    local cyan='' purple='' reset='' choice answer rc
    if [[ -t 1 && -z ${NO_COLOR:-} ]]; then cyan=$'\033[36m';purple=$'\033[35m';reset=$'\033[0m';fi
    while true; do
        [[ ${TERM:-dumb} == dumb ]] || printf '\033[2J\033[H'
        printf '%s\n   ____  _____    _    _     __  __\n  |  _ \\| ____|  / \\  | |   |  \\/  |\n  | |_) |  _|   / _ \\ | |   | |\\/| |\n  |  _ <| |___ / ___ \\| |___| |  | |\n  |_| \\_\\_____/_/   \\_\\_____|_|  |_|%s\n' "$cyan" "$reset"
        printf '\n  Realm 中转管理  ·  TCP / UDP\n'
        printf '%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$purple" "$reset"
        local version='未安装' status='未部署' count hint=''
        if [[ -x $BASE_DIR/realm ]]; then
            version=$("$BASE_DIR/realm" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
            version=${version:-程序异常}
        fi
        if [[ -f $UNIT_PATH ]]; then
            case $(systemctl is-active realm.service 2>/dev/null) in
                active) status='运行中' ;;
                activating) status='启动中' ;;
                failed) status='启动失败' ;;
                *) status='未运行' ;;
            esac
        fi
        count=$(config_tool count 2>/dev/null) || count='配置错误'
        printf '  程序 ▸ %s    服务 ▸ %s    规则 ▸ %s\n' "$version" "$status" "$count"
        printf '%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$purple" "$reset"
        if [[ $status == 未部署 ]]; then hint='下一步：选择 1 部署 Realm'
        elif [[ $count == 配置错误 ]]; then hint='配置文件有错误，选择 2 查看详情'
        elif [[ $count == 0 ]]; then hint='下一步：选择 3 添加转发规则'
        elif [[ $status == 启动失败 ]]; then hint='服务启动失败，选择 11 查看日志'
        elif [[ $status != 运行中 ]]; then hint='规则已保存但服务没在运行，选择 5 启动'
        elif config_pending; then hint='配置有改动还没生效，选择 7 重启'
        fi
        [[ -z $hint ]] || printf '  %s%s%s\n' "$cyan" "$hint" "$reset"
        printf '\n  1. 部署 Realm           7. 重启服务\n  2. 查看转发规则         8. 更新 Realm\n  3. 添加转发规则         9. 卸载 Realm\n  4. 删除转发规则        10. 更新管理脚本\n  5. 启动并开启自启      11. 查看服务日志\n  6. 停止并关闭自启      12. 安装 realmctl 快捷命令\n                        13. 查看备份\n\n  0. 退出\n\n'
        while true; do
            ask choice '请选择 [0-13]: ' || return 0
            case "$choice" in
                0|88|q|Q) return 0 ;;
                [1-9]|1[0-3]) break ;;
                '') ;;
                *) printf '没有这个选项，请输入 0 到 13。\n' ;;
            esac
        done
        case "$choice" in
            1) run_action deploy_realm || error '部署未完成。' ;;
            2) show_overview || true ;;
            3) menu_add ;;
            4) menu_delete ;;
            5) run_action start_service || error '启动没有完成。' ;;
            6) run_action stop_service || error '停止操作失败。' ;;
            7) run_action restart_service || error '重启没有完成。' ;;
            8) run_action update_realm || error '更新未完成。' ;;
            9)
                rc=0
                run_action uninstall_realm || rc=$?
                if (( rc == 0 )); then return 0; fi
                if (( rc != 2 )); then error '卸载未完成，请查看上面的提示。'; fi ;;
            10)
                rc=0
                run_action Update_Shell || rc=$?
                if (( rc == 0 )); then
                    ask answer '按回车打开新版本……' || return 0
                    exec bash "$SELF_PATH"
                fi
                if (( rc != 2 )); then error '管理脚本更新失败。'; fi ;;
            11) journalctl -u realm.service -n 50 --no-pager || true ;;
            12) run_action install_shortcut || true ;;
            13) printf '成功操作后保留最近一次备份：\n'; find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'snapshot-*' -print 2>/dev/null | grep . || printf '暂无备份。\n' ;;
        esac
        ask answer $'\n按回车返回菜单……' || return 0
    done
}
main() {
    if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage;return 0;fi
    check_platform && check_dependencies || return 1
    case ${1:-menu} in
        menu) [[ -t 0 ]] || { error '菜单需要交互终端。';return 1; };menu ;;
        list) config_tool list ;;
        status) show_overview ;;
        add)
            [[ $# == 3 || ( $# == 4 && $4 == --apply ) ]] || { usage;return 1; }
            local apply=no; [[ ${4:-} != --apply ]] || apply=yes
            run_action mutate_config add "$2" "$apply" "$3" ;;
        delete)
            [[ $# == 2 || ( $# == 3 && $3 == --apply ) ]] || { usage;return 1; }
            local apply=no; [[ ${3:-} != --apply ]] || apply=yes
            run_action mutate_config delete "$2" "$apply" ;;
        -l|-r)
            local listen='' remote='' opt OPTIND=1
            while getopts ':l:r:' opt;do case $opt in l) listen=$OPTARG;; r)remote=$OPTARG;; *)usage;return 1;; esac;done
            shift $((OPTIND-1))
            [[ -n $listen && -n $remote && $# == 0 ]] || { usage;return 1; }
            run_action mutate_config add "$listen" no "$remote" ;;
        install) run_action deploy_realm ;;
        update) run_action update_realm ;;
        start) run_action start_service ;;
        stop) run_action stop_service ;;
        restart) run_action restart_service ;;
        shortcut) run_action install_shortcut ;;
        *) usage;return 1 ;;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]];then
    set -uo pipefail
    umask 077
    # Line editing needs a UTF-8 locale to measure the Chinese prompts correctly.
    for locale_name in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if locale -a 2>/dev/null | grep -qx "$locale_name"; then export LC_ALL=$locale_name; break; fi
    done
    main "$@"
fi
