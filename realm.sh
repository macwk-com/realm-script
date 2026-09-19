#!/usr/bin/env bash
# Realm Manager — https://github.com/macwk-com/realm-script
BASE_DIR=/opt/realm
CONFIG_PATH=/etc/realm/config.toml
UNIT_PATH=/etc/systemd/system/realm.service
BACKUP_ROOT=/var/backups/realm
LOCK_PATH=/run/lock/realm-manager.lock
SCRIPT_REPO=macwk-com/realm-script
PYTHON=${PYTHON:-python3}
SELF_PATH=$(readlink -f "${BASH_SOURCE[0]}")
SHORTCUT_PATH=/usr/local/bin/realmctl
# sudo on RHEL-family systems only searches /usr/sbin and /usr/bin, so realmctl is linked there too.
SUDO_LINK=/usr/bin/realmctl
# tomlkit from PyPI when the system package is missing or older than 0.8 (Debian 10-11, Ubuntu 18-20, Rocky 8).
TOMLKIT_DIR=$BASE_DIR/python
export PYTHONPATH="$TOMLKIT_DIR${PYTHONPATH:+:$PYTHONPATH}"

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
  bash realm.sh add IP:端口 目标:端口 [--apply]
  bash realm.sh modify 序号 IP:端口 目标:端口 [--apply]
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
# tomlkit before 0.8 silently drops deletions from arrays of tables, so older copies do not count.
tomlkit_ok() {
    "$PYTHON" -c 'import sys, tomlkit
sys.exit(tuple(int(x) for x in tomlkit.__version__.split(".")[:2]) < (0, 8))' >/dev/null 2>&1
}
install_packages() {
    if command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y "$@" && return 0
        # Debian 10 and 11 are out of support; their packages moved to archive.debian.org.
        local id version
        id=$(. /etc/os-release; echo "${ID:-}") version=$(. /etc/os-release; echo "${VERSION_ID:-}")
        if [[ $id == debian && ( $version == 10 || $version == 11 ) ]]; then
            error "Debian $version 已停止维护，软件源搬到了 archive.debian.org，请先改好 /etc/apt/sources.list 再试。"
        else
            error '软件安装失败，请检查网络和软件源。'
        fi
        return 1
    elif command -v dnf >/dev/null; then
        # Rocky/Alma ship python3-tomlkit in EPEL.
        dnf install -y epel-release >/dev/null 2>&1 || true
        dnf install -y "$@"
    elif command -v yum >/dev/null; then
        yum install -y "$@"
    else
        error "请手动安装：$*"
    fi
}
check_dependencies() {
    local packages=() cmd
    command -v curl >/dev/null || packages+=(curl ca-certificates)
    command -v python3 >/dev/null || packages+=(python3)
    command -v flock >/dev/null || packages+=(util-linux)
    if (( ${#packages[@]} )); then
        printf '安装依赖：%s\n' "${packages[*]}"
        install_packages "${packages[@]}" || return 1
    fi
    for cmd in curl flock; do command -v "$cmd" >/dev/null || return 1; done
    tomlkit_ok && return 0
    # Not every release packages tomlkit, so a failure here just moves on to PyPI.
    printf '安装依赖：python3-tomlkit\n'
    install_packages python3-tomlkit >/dev/null 2>&1 || true
    tomlkit_ok && return 0
    printf '系统软件源里没有可用的 tomlkit（需要 0.8 以上），改从 PyPI 装到 %s。\n' "$TOMLKIT_DIR"
    "$PYTHON" -m pip --version >/dev/null 2>&1 || install_packages python3-pip || return 1
    mkdir -p "$TOMLKIT_DIR" && "$PYTHON" -m pip install -q --target "$TOMLKIT_DIR" 'tomlkit>=0.8' || return 1
    tomlkit_ok || { error 'tomlkit 安装失败。'; return 1; }
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
        # An optional rule number is skipped, so a rule never conflicts with itself when modified.
        host,port=address(args[0],True); skip=int(args[1]) if len(args)>1 else 0
        for index,entry in enumerate(entries,1):
            if index==skip: continue
            old,oldport=address(entry['listen'],True)
            if port==oldport and (host==old or host.is_unspecified or old.is_unspecified):
                raise ValueError(f'和第 {index} 条规则的监听端口 {port} 冲突')
        print(port)
    elif operation=='check-remote': address(args[0])
    elif operation=='set':
        if len(args)!=3: raise ValueError('修改需要序号、监听地址和目标地址')
        chosen=selection(args[0],len(entries))
        if len(chosen)!=1: raise ValueError('一次只能修改一条规则')
        index=chosen[0]; host,port=address(args[1],True); address(args[2])
        for other,entry in enumerate(entries,1):
            if other==index: continue
            old,oldport=address(entry['listen'],True)
            if port==oldport and (host==old or host.is_unspecified or old.is_unspecified):
                raise ValueError(f'和第 {other} 条规则的监听端口 {port} 冲突')
        # Only the two addresses change; transport options and comments stay.
        doc['endpoints'][index-1]['listen']=args[1]; doc['endpoints'][index-1]['remote']=args[2]
        save(doc)
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
        else printf '  %s  没有监听，请查看日志（菜单 10）\n' "$item" >&2; fi
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
    [[ ${tx_quiet:-0} == 1 ]] || printf '修改前备份：%s\n' "$tx_backup"
}
commit_transaction() {
    tx_committed=1
    prune_backups || printf '操作成功，但旧备份清理失败，请检查 %s。\n' "$BACKUP_ROOT" >&2
}
# Each operation runs in its own subshell so traps and temporary state cannot leak into the menu.
# Each operation runs in its own subshell so traps and temporary state cannot leak into the menu.
# apply=yes restarts a running service, starts a stopped one, and stops it once no rule is left.
mutate_config() (
    local op=$1 value=$2 apply=$3 extra=${4:-} extra2=${5:-} port owner proto listen=$2 remote=${4:-} skip=''
    [[ $op != modify ]] || { listen=$extra; remote=$extra2; skip=$value; }
    init_env || return 1
    if [[ $op != delete ]]; then
        port=$(config_tool check-listen "$listen" ${skip:+"$skip"}) || return 1
        config_tool check-remote "$remote" || return 1
        for proto in t u; do
            owner=$(port_owner "$port" "$proto")
            [[ -z $owner || $owner == realm ]] || { error "本机端口 $port 已被 $owner 使用，请换一个端口。"; return 1; }
        done
    fi
    begin_transaction "$CONFIG_PATH" || return 1
    case $op in
        add) config_tool add "$value" "$extra" || return 1 ;;
        modify) config_tool set "$value" "$extra" "$extra2" || return 1 ;;
        *) config_tool delete "$value" || return 1 ;;
    esac
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
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd -q --query-port="$port/tcp" 2>/dev/null && return 0
        printf '本机防火墙 firewalld 已启用，但端口 %s 还没放行，外部连不进来。可以执行：\n' "$port"
        printf '    firewall-cmd --permanent --add-port=%s/tcp --add-port=%s/udp && firewall-cmd --reload\n' "$port" "$port"
        return 0
    fi
    command -v ufw >/dev/null && status=$(ufw status 2>/dev/null) || return 0
    [[ $status == 'Status: active'* ]] || return 0
    grep -Eq "^$port(/(tcp|udp))?[[:space:]]" <<< "$status" && return 0
    command -v vpsfw >/dev/null && cmd="vpsfw ports add $port both"
    printf '本机防火墙 UFW 已启用，但端口 %s 还没放行，外部连不进来。可以执行：\n    %s\n' "$port" "$cmd"
}
fetch() { curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout 15 --max-time 180 --retry 2 "$1" -o "$2"; }
version_ge() { [[ -n $1 ]] && printf '%s\n%s\n' "$2" "$1" | sort -V -C; }
# Realm's default builds need glibc 2.38; older systems take the glibc 2.28 build, older still the static musl one.
asset_name() {
    local arch gnu musl libc
    case $(uname -m) in
        x86_64|amd64) arch=x86_64 gnu=unknown-linux-gnu musl=unknown-linux-musl ;;
        aarch64|arm64) arch=aarch64 gnu=unknown-linux-gnu musl=unknown-linux-musl ;;
        armv7l|armv7) arch=armv7 gnu=unknown-linux-gnueabihf musl=unknown-linux-musleabihf ;;
        armv6l|arm) arch=arm gnu=unknown-linux-gnueabihf musl=unknown-linux-musleabihf ;;
        *) error '不支持当前 CPU 架构，请手动安装 Realm。'; return 1 ;;
    esac
    libc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    if version_ge "$libc" 2.38; then printf 'realm-%s-%s.tar.gz\n' "$arch" "$gnu"
    elif version_ge "$libc" 2.28; then printf 'realm-%s-%s-glibc2.28.tar.gz\n' "$arch" "$gnu"
    else printf 'realm-%s-%s.tar.gz\n' "$arch" "$musl"; fi
}
# Installed Realm version such as 2.9.6, or nothing.
realm_version() {
    [[ -x $BASE_DIR/realm ]] || return 0
    "$BASE_DIR/realm" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}
# Latest release metadata: sets release_tag, release_url and release_digest.
release_info() {
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
    release_url=$(printf '%s\n' "$metadata" | sed -n '2p')
    release_digest=$(printf '%s\n' "$metadata" | sed -n '3p')
}
# Download, verify and stage the release found by release_info.
prepare_release() {
    printf '下载 Realm %s\n' "$release_tag"
    fetch "$release_url" "$stage_dir/realm.tar.gz" || return 1
    "$PYTHON" - "$stage_dir" "$release_digest" <<'PY'
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
# deploy_realm [install|update]: install skips an existing deployment; update skips when already
# on the latest release and asks before restarting a running service. Returns 2 when cancelled.
deploy_realm() (
    local mode=${1:-install} current
    current=$(realm_version)
    if [[ $mode == install && -n $current && -f $UNIT_PATH ]]; then
        printf 'Realm 已经部署（版本 %s），要升级请选择菜单 9「更新 Realm」。\n' "$current"
        return 0
    fi
    init_env || return 1
    stage_dir=$(mktemp -d "$BASE_DIR/.download-XXXXXXXX") || return 1
    trap 'rm -rf -- "$stage_dir"' EXIT
    release_info || return 1
    if [[ $mode == update && $current == "${release_tag#v}" ]]; then
        printf 'Realm 已经是最新版 %s，不需要更新。\n' "$current"
        return 0
    fi
    if [[ $mode == update && -t 0 ]] && systemctl is-active --quiet realm.service; then
        printf 'Realm %s → %s\n' "${current:-未知版本}" "${release_tag#v}"
        confirm '更新要重启 Realm，正在转发的连接会断开一下。现在更新？' y || { printf '已取消，没有更新。\n'; return 2; }
    fi
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
        printf 'Realm %s 已安装。下一步：添加转发规则（菜单 2）。\n' "$release_tag"
    else
        printf 'Realm %s 已安装，现有规则保留。服务还没启动，可以选择菜单 5 启动。\n' "$release_tag"
    fi
    commit_transaction
)
update_realm() { [[ -x $BASE_DIR/realm ]] || { error '请先部署 Realm。'; return 1; }; deploy_realm update; }
# Realm exits immediately without endpoints, so refuse to start it empty.
require_rules() {
    [[ -x $BASE_DIR/realm && -f $UNIT_PATH ]] || { error 'Realm 还没部署，请先选择菜单 8。'; return 1; }
    config_tool validate || return 1
    [[ $(config_tool count) != 0 ]] || { error '还没有转发规则，请先添加（菜单 2）。'; return 1; }
}
start_service() {
    require_rules || return 1
    systemctl daemon-reload && systemctl start realm.service && wait_service && systemctl enable --quiet realm.service || return 1
    printf 'Realm 已启动并设为开机自启，所有端口都在正常监听。\n'
}
stop_service() {
    [[ -f $UNIT_PATH ]] || { error 'Realm 还没部署。'; return 1; }
    if ! systemctl is-active --quiet realm.service && ! systemctl is-enabled --quiet realm.service; then
        printf 'Realm 本来就没在运行，也没有设开机自启。\n'
        return 0
    fi
    systemctl stop realm.service && systemctl disable --quiet realm.service || return 1
    if systemctl is-active --quiet realm.service; then error '服务仍在运行。'; return 1; fi
    printf 'Realm 已停止，开机自启已禁用。\n'
}
restart_service() {
    require_rules || return 1
    systemctl restart realm.service && wait_service || return 1
    printf 'Realm 已重启，所有端口都在正常监听。\n'
}
# Lists and removes only what actually exists; returns 2 when cancelled or there is nothing to remove.
uninstall_realm() (
    local candidate cleanup_failed=0 installed=0 active=0 backups
    local targets=() scripts=() removed=()
    [[ ! -e $BASE_DIR/realm ]] || { targets+=("$BASE_DIR/realm"); removed+=('Realm 程序'); }
    [[ ! -e $UNIT_PATH ]] || { targets+=("$UNIT_PATH"); removed+=('systemd 服务'); }
    [[ ! -e $CONFIG_PATH ]] || { targets+=("$CONFIG_PATH"); removed+=('转发配置'); }
    (( ${#targets[@]} == 0 )) || installed=1
    systemctl is-active --quiet realm.service && active=1
    for candidate in "$SELF_PATH" "$SHORTCUT_PATH"; do
        [[ -f $candidate && ! -L $candidate ]] || continue
        if grep -Fq '# Realm Manager —' "$candidate"; then
            # Deduplicate aliases such as SELF_PATH == SHORTCUT_PATH.
            local already=0 existing
            for existing in ${scripts[@]+"${scripts[@]}"}; do [[ $existing != "$candidate" ]] || already=1; done
            (( already )) || scripts+=("$candidate")
        fi
    done
    targets+=(${scripts[@]+"${scripts[@]}"})
    (( ${#scripts[@]} == 0 )) || removed+=('管理脚本')
    backups=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'snapshot-*' 2>/dev/null | wc -l)
    (( backups == 0 )) || removed+=("$backups 份操作备份")
    [[ ! -d $TOMLKIT_DIR ]] || removed+=('Python 依赖')
    if (( ${#removed[@]} == 0 && ! active )); then
        printf '\n这台服务器上没有安装 Realm，也没有需要删除的管理脚本或备份。\n'
        return 2
    fi
    printf '\n'
    (( installed || active )) || printf '这台服务器上没有安装 Realm（没有程序、服务和转发配置）。\n'
    printf '完整卸载会删除：\n'
    for candidate in ${targets[@]+"${targets[@]}"}; do printf '  %s\n' "$candidate"; done
    (( backups == 0 )) || printf '  %s 里的 %s 份操作备份\n' "$BACKUP_ROOT" "$backups"
    [[ ! -d $TOMLKIT_DIR ]] || printf '  %s（从 PyPI 装的 tomlkit）\n' "$TOMLKIT_DIR"
    [[ ! -L $SUDO_LINK || $(readlink -f "$SUDO_LINK") != "$SHORTCUT_PATH" ]] || printf '  %s（给 sudo 用的链接）\n' "$SUDO_LINK"
    (( ! active )) || printf 'Realm 正在运行，会先停止，所有转发立即中断。\n'
    (( ${#scripts[@]} == 0 )) || printf '删除管理脚本后，要重新执行一键安装命令才能再用。\n'
    printf '不会动系统日志、依赖包、防火墙规则和其他程序的文件；只移除空目录。\n'
    if [[ -e $CONFIG_PATH ]]; then confirm '确认完整卸载？转发配置和备份都不会保留' || return 2
    else confirm '确认删除？' || return 2; fi
    init_env || return 1
    local tx_quiet=1
    begin_transaction ${targets[@]+"${targets[@]}"} || return 1
    local enabled=0
    systemctl is-enabled --quiet realm.service && enabled=1
    service_touched=1
    # A missing service is already stopped; real stop failures must preserve all files.
    if systemctl is-active --quiet realm.service || [[ -f $UNIT_PATH ]]; then
        systemctl stop realm.service || return 1
    fi
    if systemctl is-active --quiet realm.service; then error '服务仍在运行，已停止卸载。'; return 1; fi
    if (( enabled )); then systemctl disable --quiet realm.service || return 1; fi
    (( ${#targets[@]} == 0 )) || rm -f -- "${targets[@]}" || return 1
    systemctl daemon-reload || return 1
    # Recovery remains possible until service removal and script deletion succeed.
    # Complete uninstall explicitly discards the transaction snapshot afterwards.
    tx_committed=1
    # Both are ours alone: the private tomlkit copy and the sudo link to a realmctl that is now gone.
    rm -rf -- "$TOMLKIT_DIR" || cleanup_failed=1
    if [[ -L $SUDO_LINK && $(readlink "$SUDO_LINK") == "$SHORTCUT_PATH" ]]; then rm -f -- "$SUDO_LINK" || cleanup_failed=1; fi
    "$PYTHON" - "$BASE_DIR" "$CONFIG_PATH" "$BACKUP_ROOT" <<'PY'
import pathlib,re,shutil,sys
base,config,backups=map(pathlib.Path,sys.argv[1:])
if backups.is_symlink(): raise SystemExit('备份目录是软链接，拒绝清理其内容')
if backups.exists():
    for p in backups.iterdir():
        if p.is_dir() and not p.is_symlink() and re.fullmatch(r'snapshot-[A-Za-z0-9]{8}',p.name) and (p/'manifest.json').is_file():
            shutil.rmtree(p)
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
    local summary='' item
    for item in ${removed[@]+"${removed[@]}"}; do summary+=${summary:+、}$item; done
    printf '完整卸载完成，已删除：%s。\n' "${summary:-Realm 服务}"
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
    copy=$SHORTCUT_PATH
    if [[ $copy != "$SELF_PATH" && -f $copy && ! -L $copy ]] && grep -Fq '# Realm Manager —' "$copy"; then
        atomic_install "$SELF_PATH" "$copy" 755 && printf '已同步更新 %s\n' "$copy"
    fi
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
# The first run from a downloaded file installs the realmctl command; an existing one is left alone.
link_for_sudo() {
    local path
    [[ -f $SHORTCUT_PATH ]] || return 0
    path=$(sudo -V 2>/dev/null | sed -n 's/^Value to override user.s \$PATH with: //p') || path=''
    [[ -n $path && :$path: != *:${SHORTCUT_PATH%/*}:* ]] || return 0
    if [[ ! -e $SUDO_LINK || ( -L $SUDO_LINK && $(readlink -f "$SUDO_LINK") == "$SHORTCUT_PATH" ) ]]; then
        ln -sfn "$SHORTCUT_PATH" "$SUDO_LINK"
    fi
}
ensure_shortcut() {
    [[ $SELF_PATH != "$SHORTCUT_PATH" && -f $SELF_PATH && ! -e $SHORTCUT_PATH && ! -L $SHORTCUT_PATH ]] || return 1
    grep -Fq '# Realm Manager —' "$SELF_PATH" || return 1
    atomic_install "$SELF_PATH" "$SHORTCUT_PATH" 755
}
show_overview() {
    set_colors
    local state color note version active=0 pending=0 started rows count broken=0
    local index listen remote port protos cell cell_color proto owner
    rows=$(config_tool rows) || return 1
    count=0; [[ -z $rows ]] || count=$(wc -l <<< "$rows")
    if [[ ! -x $BASE_DIR/realm || ! -f $UNIT_PATH ]]; then
        state='● 未部署'; color=$c_err; note='选择 8 部署 Realm'
    else
        version=$(realm_version)
        case $(systemctl is-active realm.service 2>/dev/null) in
            active)
                active=1; state='● 运行中'; color=$c_ok
                started=$(systemctl show realm.service -p ActiveEnterTimestamp --value 2>/dev/null)
                note="${version:-版本未知} · "
                if systemctl is-enabled --quiet realm.service; then note+='开机自启'; else note+='未设开机自启'; fi
                [[ -z $started ]] || note+=" · 已运行 $(human_uptime $(( $(date +%s) - $(date -d "$started" +%s) )))"
                config_pending && pending=1 ;;
            failed) state='● 启动失败'; color=$c_err; note='选择 10 查看日志' ;;
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
        printf '  %s无，选择 2 添加%s\n\n' "$c_dim" "$c_off"
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
    (( ! broken )) || printf '  %s有端口没监听成功：被占用的请换端口，其他情况选择 10 查看日志。%s\n' "$c_err" "$c_off"
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
    [[ -x $BASE_DIR/realm && -f $UNIT_PATH ]] || { printf 'Realm 还没部署，规则先保存，部署后启动即可生效（菜单 8）。\n'; return 0; }
    if systemctl is-active --quiet realm.service; then
        if confirm '立即重启 Realm 让改动生效？正在转发的连接会断开一下' y; then apply=yes; fi
    elif [[ $1 == add ]]; then
        if confirm 'Realm 现在没有运行，保存后启动它？' y; then apply=yes; fi
    fi
}
# Ask for the remote port when the answer has none (a bare IPv6 gets brackets); REPLY holds the target.
complete_remote() {
    local value=$1 rport
    if [[ $value != *:* || $value == \[*\] || ( $value == *:*:* && $value != \[* ) ]]; then
        [[ $value == *:* && $value != \[* ]] && value="[$value]"
        ask rport '远程端口: ' && [[ -n $rport ]] || return 1
        value="$value:$rport"
    fi
    REPLY=$value
}
menu_add() {
    local value listen remote port owner proto apply msg
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
        complete_remote "$value" || return 0
        remote=$REPLY
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
menu_modify() {
    local count value index cur_listen cur_remote listen remote port owner proto apply msg
    count=$(config_tool count) || return 0
    (( count > 0 )) || { printf '\n还没有转发规则。\n'; return 0; }
    printf '\n'
    config_tool list
    printf '\n'
    while true; do
        ask value '要修改哪一条？输入序号（回车返回）: ' && [[ -n $value ]] || return 0
        [[ $value =~ ^[0-9]+$ ]] && (( 10#$value >= 1 && 10#$value <= count )) && break
        printf '请输入 1 到 %s 之间的序号。\n' "$count"
    done
    index=$((10#$value))
    IFS=$'\t' read -r _ cur_listen cur_remote _ _ <<< "$(config_tool rows | sed -n "${index}p")"
    printf '\n第 %s 条现在是：%s  →  %s\n直接回车表示这一项不改。\n\n' "$index" "$cur_listen" "$cur_remote"
    while true; do
        ask value "本机监听端口 [${cur_listen##*:}]: " || return 0
        if [[ -z $value ]]; then listen=$cur_listen
        elif [[ $value =~ ^[0-9]+$ ]]; then listen="${cur_listen%:*}:$value"
        else listen=$value; fi
        port=$(config_tool check-listen "$listen" "$index" 2>&1) || { printf '%s\n' "${port#配置操作失败：}"; continue; }
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
        ask value "远程目标 [$cur_remote]: " || return 0
        if [[ -z $value ]]; then remote=$cur_remote
        else complete_remote "$value" || return 0; remote=$REPLY; fi
        msg=$(config_tool check-remote "$remote" 2>&1) && break
        printf '%s\n' "${msg#配置操作失败：}"
    done
    if [[ $listen == "$cur_listen" && $remote == "$cur_remote" ]]; then printf '没有改动。\n'; return 0; fi
    printf '\n将修改第 %s 条：\n  原来  %s  →  %s\n  改为  %s  →  %s\n' "$index" "$cur_listen" "$cur_remote" "$listen" "$remote"
    ask_apply modify
    if run_action mutate_config modify "$index" "$apply" "$listen" "$remote"; then
        [[ ${listen##*:} == "${cur_listen##*:}" ]] || firewall_hint "$port"
    else
        error '修改没有完成，配置没有改动。'
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
# Menu layout follows vps-firewall: aligned two columns, blank line between rows, one column when narrow.
menu_pair() {
    text_width "$1"
    local padding=$((28 - REPLY))
    (( padding >= 0 )) || padding=0
    printf '  %s%*s    %s\n' "$1" "$padding" '' "$2"
}
menu_item() { printf '  %s%2s.%s %s' "$cyan" "$1" "$reset" "$2"; }
menu_rule() {
    local line
    printf -v line '%*s' "$menu_span" ''
    printf '  %s%s%s\n' "$blue" "${line// /─}" "$reset"
}
menu_draw() {
    local columns=$1 version=$2 status=$3 count=$4 protocols=$5 title=$6 detail=$7 note=${8:-}
    local cyan='' blue='' reset='' bold='' dim=''
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
        cyan=$'\033[36m'; blue=$'\033[34m'; reset=$'\033[0m'
        bold=$'\033[1m'; dim=$'\033[90m'
    fi
    local menu_span=60 wide=1 i padding
    if (( columns < 64 )); then
        wide=0; menu_span=$((columns - 4))
        (( menu_span >= 24 )) || menu_span=24
    fi
    printf '\n'
    if (( columns >= 44 )); then
        printf '%s' "$cyan"
        cat <<'LOGO'
   ____  _____    _    _     __  __
  |  _ \| ____|  / \  | |   |  \/  |
  | |_) |  _|   / _ \ | |   | |\/| |
  |  _ <| |___ / ___ \| |___| |  | |
  |_| \_\_____/_/   \_\_____|_|  |_|
LOGO
        printf '%s' "$reset"
    fi
    printf '\n  %sRealm 中转管理  ·  TCP / UDP%s\n' "$bold" "$reset"
    printf '  %s端口转发的部署、规则与服务管理%s\n\n' "$dim" "$reset"
    menu_rule
    if (( wide )); then
        menu_pair "程序      $version" "服务      $status"
        menu_pair "规则      $count" "协议      $protocols"
    else
        printf '  程序      %s\n  服务      %s\n  规则      %s\n  协议      %s\n' "$version" "$status" "$count" "$protocols"
    fi
    menu_rule
    printf '\n'
    local labels=('查看转发规则' '添加转发规则' '修改转发规则' '删除转发规则' '启动并开启自启' '停止并关闭自启' '重启服务'
                  '部署 Realm' '更新 Realm' '查看服务日志' '更新管理脚本' '卸载 Realm')
    if (( wide )); then
        menu_pair '日常操作' '安装与维护'
        printf '\n'
        for ((i=0;i<7;i++)); do
            menu_item "$((i+1))" "${labels[i]}"
            if (( i < 5 )); then
                text_width "${labels[i]}"; padding=$((28 - 4 - REPLY))
                # The first column already supplied the row indentation.
                printf '%*s    %s%2s.%s %s' "$padding" '' "$cyan" "$((i+8))" "$reset" "${labels[i+7]}"
            fi
            printf '\n\n'
        done
    else
        printf '  %s日常操作%s\n\n' "$dim" "$reset"
        for ((i=0;i<12;i++)); do
            (( i != 7 )) || printf '\n  %s安装与维护%s\n\n' "$dim" "$reset"
            menu_item "$((i+1))" "${labels[i]}"; printf '\n\n'
        done
    fi
    menu_rule
    menu_item 0 '退出'; printf '\n'; menu_rule
    [[ -z $note ]] || printf '\n  %s已安装快捷命令 realmctl%s\n  以后直接输入 realmctl 就能打开这个菜单。\n' "$cyan" "$reset"
    [[ -z $title ]] || printf '\n  %s%s%s\n  %s\n' "$cyan" "$title" "$reset" "$detail"
    printf '\n'
}
menu() {
    local choice answer rc columns
    while true; do
        [[ ${TERM:-dumb} == dumb ]] || printf '\033[2J\033[H'
        local version='未安装' status='未部署' count protocols='—' title='' detail=''
        if [[ -x $BASE_DIR/realm ]]; then
            version=$(realm_version)
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
        protocols=$(config_tool protocols 2>/dev/null) || protocols='—'
        if [[ $status == 未部署 ]]; then title='尚未部署'; detail='新服务器请先选择 8。'
        elif [[ $count == 配置错误 ]]; then title='配置文件有错误'; detail='选择 1 查看详情。'
        elif [[ $count == 0 ]]; then title='还没有转发规则'; detail='选择 2 添加第一条。'
        elif [[ $status == 启动失败 ]]; then title='服务启动失败'; detail='选择 10 查看日志。'
        elif [[ $status != 运行中 ]]; then title='服务没在运行'; detail='规则已保存，选择 5 启动。'
        elif config_pending; then title='配置有改动还没生效'; detail='选择 7 重启。'
        fi
        [[ $count == 配置错误 ]] || count="$count 条"
        columns=$(tput cols 2>/dev/null) || columns=${COLUMNS:-80}
        [[ $columns =~ ^[0-9]+$ ]] || columns=80
        menu_draw "$columns" "$version" "$status" "$count" "$protocols" "$title" "$detail" "${shortcut_installed:-}"
        shortcut_installed=''
        while true; do
            ask choice '  请选择 [0-12]: ' || return 0
            case "$choice" in
                0|q|Q) return 0 ;;
                [1-9]|1[0-2]) break ;;
                '') ;;
                *) printf '  没有这个选项，请输入 0 到 12。\n' ;;
            esac
        done
        case "$choice" in
            1) show_overview || true ;;
            2) menu_add ;;
            3) menu_modify ;;
            4) menu_delete ;;
            5) run_action start_service || error '启动没有完成。' ;;
            6) run_action stop_service || error '停止操作失败。' ;;
            7) run_action restart_service || error '重启没有完成。' ;;
            8) run_action deploy_realm || error '部署未完成。' ;;
            9)
                rc=0
                run_action update_realm || rc=$?
                (( rc == 0 || rc == 2 )) || error '更新未完成。' ;;
            10) journalctl -u realm.service -n 50 --no-pager || true ;;
            11)
                rc=0
                run_action Update_Shell || rc=$?
                if (( rc == 0 )); then
                    ask answer '按回车打开新版本……' || return 0
                    exec bash "$SELF_PATH"
                fi
                if (( rc != 2 )); then error '管理脚本更新失败。'; fi ;;
            12)
                rc=0
                run_action uninstall_realm || rc=$?
                if (( rc == 0 )); then return 0; fi
                if (( rc != 2 )); then error '卸载未完成，请查看上面的提示。'; fi ;;
        esac
        ask answer $'\n按回车返回菜单……' || return 0
    done
}
main() {
    if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage;return 0;fi
    check_platform && check_dependencies || return 1
    link_for_sudo
    if ensure_shortcut; then
        shortcut_installed=1
        [[ ${1:-menu} == menu ]] || printf '已安装快捷命令 realmctl，以后直接输入 realmctl 即可。\n'
    fi
    case ${1:-menu} in
        menu) [[ -t 0 ]] || { error '菜单需要交互终端。';return 1; };menu ;;
        list) config_tool list ;;
        status) show_overview ;;
        add)
            [[ $# == 3 || ( $# == 4 && $4 == --apply ) ]] || { usage;return 1; }
            local apply=no; [[ ${4:-} != --apply ]] || apply=yes
            run_action mutate_config add "$2" "$apply" "$3" ;;
        modify)
            [[ $# == 4 || ( $# == 5 && $5 == --apply ) ]] || { usage;return 1; }
            local apply=no; [[ ${5:-} != --apply ]] || apply=yes
            run_action mutate_config modify "$2" "$apply" "$3" "$4" ;;
        delete)
            [[ $# == 2 || ( $# == 3 && $3 == --apply ) ]] || { usage;return 1; }
            local apply=no; [[ ${3:-} != --apply ]] || apply=yes
            run_action mutate_config delete "$2" "$apply" ;;
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
