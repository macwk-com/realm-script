"""Isolated regression tests; never touch /root, systemd, or the network."""
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import tempfile
import unittest

import tomlkit

SCRIPT = Path(__file__).resolve().parents[1] / 'realm.sh'


class RealmTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'config' / 'config.toml'
        self.base = self.root / 'bin'
        self.backups = self.root / 'backups'
        self.unit = self.root / 'systemd' / 'realm.service'
        for p in (self.config.parent, self.base, self.backups, self.unit.parent):
            p.mkdir(parents=True, exist_ok=True)
        self.mocks = r'''
systemctl() {
    printf '%s\n' "$*" >> "$TEST_ROOT/events"
    case "$1" in
        is-active) [[ -e $TEST_ROOT/active ]] ;;
        is-enabled) [[ -e $TEST_ROOT/enabled ]] ;;
        start|restart)
            if [[ -e $TEST_ROOT/fail-once ]]; then
                rm -f "$TEST_ROOT/fail-once" "$TEST_ROOT/active"; return 1
            fi
            touch "$TEST_ROOT/active" ;;
        stop) rm -f "$TEST_ROOT/active" ;;
        enable) touch "$TEST_ROOT/enabled" ;;
        disable) rm -f "$TEST_ROOT/enabled" ;;
        daemon-reload) return 0 ;;
    esac
}
wait_service() { systemctl is-active --quiet realm.service; }
check_platform() { :; }
check_dependencies() { :; }
run_action() { "$@"; }
latest_commit() { echo main; }
'''

    def shell(self, body, expected=0, extra=''):
        assignments = {
            'CONFIG_PATH': self.config, 'BASE_DIR': self.base,
            'BACKUP_ROOT': self.backups, 'UNIT_PATH': self.unit,
            'PYTHON': sys.executable, 'TEST_ROOT': self.root,
            'SELF_PATH': self.root/'manager.sh',
            'SHORTCUT_PATH': self.root/'realmctl',
            'LEGACY_SCRIPT': self.root/'realm.sh',
        }
        code = 'set -uo pipefail\nsource ' + shlex.quote(str(SCRIPT)) + '\n'
        code += '\n'.join(k + '=' + shlex.quote(str(v)) for k, v in assignments.items())
        code += '\n' + self.mocks + '\n' + extra + '\n' + body
        result = subprocess.run(['bash', '-c', code], capture_output=True, text=True)
        if expected == 0:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def write_rules(self, n=2, comment=True):
        text = '[network]\nuse_udp = true\nno_tcp = false\n'
        for i in range(n):
            if comment:
                text += '# A valid comment before endpoint\n'
            text += f'[[endpoints]] # rule {i+1}\nlisten = "0.0.0.0:{12000+i}"\nremote = "example.com:443"\n'
            text += 'listen_transport = "tls"\nremote_transport = "tls;sni=example.com"\n'
        text += '\n[log]\nlevel = "warn" # keep this comment\n[dns]\nmode = "ipv4_only"\n'
        self.config.write_text(text)
        return text

    def parsed(self):
        return tomlkit.parse(self.config.read_text())

    def fake_release(self, corrupt_digest=False):
        payload = b'#!/bin/sh\nprintf "realm 2.9.6\\n"\n'
        archive = self.root / 'release.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            info = tarfile.TarInfo('realm'); info.size = len(payload); info.mode = 0o755
            tar.addfile(info, io.BytesIO(payload))
            # Extraneous archive paths must never be extracted.
            info = tarfile.TarInfo('../../unexpected'); info.size = 3
            tar.addfile(info, io.BytesIO(b'bad'))
        asset = 'realm-x86_64-unknown-linux-gnu.tar.gz'
        digest = '0'*64 if corrupt_digest else hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.root/'release.json').write_text(json.dumps({
            'tag_name': 'v2.9.6', 'assets': [{
                'name': asset,
                'browser_download_url': 'https://github.com/zhboner/realm/releases/download/v2.9.6/'+asset,
                'digest': 'sha256:'+digest,
            }],
        }))
        return r'''
uname() { echo x86_64; }
fetch() {
    if [[ $1 == *api.github.com* ]]; then cp "$TEST_ROOT/release.json" "$2"
    else cp "$TEST_ROOT/release.tar.gz" "$2"; fi
}
'''

    def install_old(self):
        (self.base/'realm').write_text('#!/bin/sh\necho "realm 2.7.0"\n')
        (self.base/'realm').chmod(0o755)
        self.unit.write_text('[Service]\n# existing custom service\n')

    def test_syntax(self):
        subprocess.run(['bash', '-n', str(SCRIPT)], check=True)

    def test_list_uses_exact_fields(self):
        self.write_rules()
        out = self.shell('config_tool list').stdout
        self.assertIn('0.0.0.0:12000', out)
        self.assertIn('example.com:443', out)
        self.assertNotIn('tls;sni', out)

    def test_delete_comments_range_and_global_tables(self):
        self.write_rules(3)
        self.shell('mutate_config delete 2-3 no')
        doc = self.parsed()
        self.assertEqual(len(doc['endpoints']), 1)
        self.assertEqual(doc['log']['level'], 'warn')
        self.assertEqual(doc['dns']['mode'], 'ipv4_only')
        self.assertIn('# keep this comment', self.config.read_text())
        self.shell('mutate_config delete 1 no')
        self.assertNotIn('endpoints', self.parsed())
        self.assertIn('log', self.parsed())

    def test_cli_initializes_missing_directory(self):
        self.config.parent.rmdir()
        self.shell('main -l 0.0.0.0:23456 -r example.com:443')
        self.assertEqual(self.parsed()['endpoints'][0]['listen'], '0.0.0.0:23456')
        self.assertTrue(self.parsed()['network']['use_udp'])

    def test_bad_input_and_duplicates_preserve_config(self):
        original = self.write_rules()
        for listen,remote in [('0.0.0.0:0','example.com:443'),('0.0.0.0:65536','example.com:443'),
                              ('0.0.0.0:12000','example.com:443'),('127.0.0.1:12000','example.com:443'),
                              ('0.0.0.0:24444','bad"host:443'),('0.0.0.0:24444','[2001:db8::1]:0')]:
            self.shell('mutate_config add '+shlex.quote(listen)+' no '+shlex.quote(remote), expected=1)
            self.assertEqual(self.config.read_text(),original)

    def test_ipv6_and_unrelated_settings_survive_add(self):
        self.write_rules()
        self.shell("mutate_config add '[::1]:23456' no '[2001:db8::1]:443'")
        self.assertEqual(self.parsed()['endpoints'][-1]['remote'],'[2001:db8::1]:443')
        self.assertEqual(self.parsed()['log']['level'],'warn')

    def test_invalid_toml_unchanged(self):
        self.config.write_text('[[endpoints\n')
        self.shell('mutate_config add 0.0.0.0:23456 no example.com:443',expected=1)
        self.assertEqual(self.config.read_text(),'[[endpoints\n')

    def test_restart_failure_restores_config_and_service(self):
        original = self.write_rules();self.install_old()
        (self.root/'active').touch();(self.root/'fail-once').touch()
        self.shell('mutate_config delete 1 yes',expected=1)
        self.assertEqual(self.config.read_text(),original)
        self.assertTrue((self.root/'active').exists())

    def test_apply_uninstalled_rolls_back_new_config(self):
        self.shell('mutate_config add 0.0.0.0:23456 yes example.com:443',expected=1)
        self.assertFalse(self.config.exists())

    def test_write_failure_nonzero(self):
        self.config.mkdir()
        self.shell('main -l 0.0.0.0:23456 -r example.com:443',expected=1)
        self.assertTrue(self.config.is_dir())

    def test_download_failure_preserves_existing_install(self):
        original=self.write_rules();self.install_old()
        before=(self.base/'realm').read_bytes()
        self.shell('deploy_realm',expected=1,extra='fetch() { return 22; }')
        self.assertEqual(self.config.read_text(),original)
        self.assertEqual((self.base/'realm').read_bytes(),before)
        self.assertFalse(list(self.base.glob('.download-*')))

    def test_deploy_preserves_config_and_unit(self):
        original=self.write_rules();self.install_old();unit=self.unit.read_bytes()
        self.shell('deploy_realm',extra=self.fake_release())
        self.assertEqual(self.config.read_text(),original)
        self.assertEqual(self.unit.read_bytes(),unit)
        self.assertIn(b'2.9.6',(self.base/'realm').read_bytes())
        self.assertFalse((self.root/'unexpected').exists())

    def test_failed_upgrade_restores_binary_and_running_service(self):
        original=self.write_rules();self.install_old();binary=(self.base/'realm').read_bytes()
        (self.root/'active').touch();(self.root/'fail-once').touch()
        self.shell('deploy_realm',expected=1,extra=self.fake_release())
        self.assertEqual((self.base/'realm').read_bytes(),binary)
        self.assertEqual(self.config.read_text(),original)
        self.assertTrue((self.root/'active').exists())

    def test_digest_failure_does_not_install(self):
        self.shell('deploy_realm',expected=1,extra=self.fake_release(corrupt_digest=True))
        self.assertFalse((self.base/'realm').exists())
        self.assertFalse(self.config.exists())

    def test_success_keeps_one_backup_failure_preserves_previous(self):
        self.write_rules(3)
        self.shell('mutate_config delete 3 no')
        backups=list(self.backups.glob('snapshot-*'));self.assertEqual(len(backups),1)
        self.shell('mutate_config delete 99 no',expected=1)
        self.assertTrue(backups[0].exists())
        self.shell('mutate_config delete 2 no')
        self.assertEqual(len(list(self.backups.glob('snapshot-*'))),1)

    def test_uninstall_removes_managed_files_and_all_backups(self):
        self.write_rules(); self.install_old()
        scripts = [self.root/'manager.sh', self.root/'realmctl', self.root/'realm.sh', self.base/'realm.sh']
        for p in scripts:
            p.write_text('#!/bin/bash\n# Realm Manager —\n')
        (self.root/'active').touch(); (self.root/'enabled').touch()
        self.shell('snapshot "$CONFIG_PATH"')
        (self.base/'realm-v2.7.0.tar.gz').touch()
        self.shell('uninstall_realm', extra='confirm() { return 0; }')
        for p in scripts + [self.config, self.unit, self.backups, self.base, self.root/'active', self.root/'enabled']:
            self.assertFalse(p.exists(), str(p))

    def test_uninstall_preserves_unrelated_files(self):
        self.write_rules(); self.install_old()
        kept = [self.root/'realmctl', self.base/'notes.txt', self.config.parent/'other.conf']
        for p in kept: p.write_text('unrelated')
        self.shell('uninstall_realm', extra='confirm() { return 0; }')
        for p in kept: self.assertEqual(p.read_text(), 'unrelated')

    def test_uninstall_cancel_preserves_install(self):
        original = self.write_rules(); self.install_old()
        self.shell('uninstall_realm', expected=1, extra='confirm() { return 1; }')
        self.assertEqual(self.config.read_text(), original)
        self.assertTrue((self.base/'realm').exists())
        self.assertFalse(list(self.backups.iterdir()))

    def test_uninstall_delete_failure_restores_files_and_service(self):
        original = self.write_rules(); self.install_old()
        manager = self.root/'manager.sh'
        manager.write_text('# Realm Manager —\n')
        (self.root/'active').touch(); (self.root/'enabled').touch()
        self.shell('uninstall_realm', expected=1, extra='''
confirm() { return 0; }
rm() {
    if [[ $* == *"$UNIT_PATH"* ]]; then
        command rm -f "$BASE_DIR/realm" "$SELF_PATH"; return 1
    fi
    command rm "$@"
}
''')
        self.assertEqual(self.config.read_text(), original)
        for p in (self.base/'realm', manager, self.unit, self.root/'active', self.root/'enabled'):
            self.assertTrue(p.exists(), str(p))

    def test_menu_uninstall_success_exits(self):
        self.write_rules(); self.install_old()
        result = self.shell("TERM=dumb; menu <<< 9", extra='confirm() { return 0; }')
        self.assertIn('完整卸载完成', result.stdout)
        self.assertEqual(result.stdout.count('Realm 中转管理'), 1)

    def test_menu_renders_and_exits(self):
        result=self.shell("TERM=dumb; menu <<< 0")
        self.assertIn('Realm 中转管理',result.stdout)
        self.assertIn('查看备份',result.stdout)

    def test_self_update_targets_running_script_not_working_directory(self):
        current=self.root/'manager.sh'
        current.write_text('#!/bin/bash\n# Realm Manager —\necho old\n')
        replacement=self.root/'replacement.sh'
        replacement.write_text('#!/bin/bash\n# Realm Manager —\necho new\n')
        self.shell('SELF_PATH='+shlex.quote(str(current))+'; Update_Shell',
                   extra='confirm() { return 0; }; fetch() { cp "$TEST_ROOT/replacement.sh" "$2"; }')
        self.assertEqual(current.read_text(),replacement.read_text())
        self.assertEqual(len(list(self.backups.glob('snapshot-*'))),1)

    def test_failed_self_update_does_not_replace_script(self):
        current=self.root/'manager.sh';current.write_text('#!/bin/bash\n# Realm Manager —\necho old\n')
        self.shell('SELF_PATH='+shlex.quote(str(current))+'; Update_Shell',expected=1,
                   extra='confirm() { return 0; }; fetch() { printf "if broken" > "$2"; }')
        self.assertIn('echo old',current.read_text())

    def test_delete_accepts_list(self):
        self.write_rules(4)
        self.shell("mutate_config delete '1,3' no")
        self.assertEqual([e['listen'] for e in self.parsed()['endpoints']], ['0.0.0.0:12001', '0.0.0.0:12003'])

    def test_deleting_last_rule_stops_service(self):
        self.write_rules(1); self.install_old()
        (self.root/'active').touch(); (self.root/'enabled').touch()
        self.shell('mutate_config delete 1 yes')
        self.assertNotIn('endpoints', self.parsed())
        self.assertFalse((self.root/'active').exists())
        self.assertFalse((self.root/'enabled').exists())

    def test_apply_starts_stopped_service(self):
        self.write_rules(1); self.install_old()
        self.shell('mutate_config add 0.0.0.0:23456 yes example.com:443')
        self.assertTrue((self.root/'active').exists())
        self.assertTrue((self.root/'enabled').exists())

    def test_add_rejects_port_used_by_other_program(self):
        original = self.write_rules(1)
        result = self.shell('mutate_config add 0.0.0.0:22 no example.com:443', expected=1,
                            extra='port_owner() { [[ $1 == 22 ]] && echo sshd; }')
        self.assertIn('sshd', result.stderr)
        self.assertEqual(self.config.read_text(), original)

    def test_check_listen_reports_conflicting_rule(self):
        self.write_rules(2)
        result = self.shell('config_tool check-listen 127.0.0.1:12001', expected=1)
        self.assertIn('第 2 条', result.stderr)

    def test_unbound_port_fails_apply_and_restores(self):
        original = self.write_rules(1); self.install_old()
        (self.root/'active').touch()
        result = self.shell('mutate_config add 0.0.0.0:23456 yes example.com:443', expected=1,
                            extra='sleep() { :; }; port_owner() { [[ $1 == 12000 ]] && echo realm; }; wait_service() { wait_listening; }')
        self.assertIn('23456/tcp', result.stderr)
        self.assertEqual(self.config.read_text(), original)

    def test_self_update_syncs_shortcut_copy(self):
        current=self.root/'manager.sh'; shortcut=self.root/'realmctl'
        for p in (current, shortcut): p.write_text('#!/bin/bash\n# Realm Manager —\necho old\n')
        (self.root/'replacement.sh').write_text('#!/bin/bash\n# Realm Manager —\necho new\n')
        self.shell('Update_Shell', extra='confirm() { return 0; }; fetch() { cp "$TEST_ROOT/replacement.sh" "$2"; }')
        self.assertIn('echo new', shortcut.read_text())

    def test_rows_follow_network_switches(self):
        self.config.write_text('[network]\nuse_udp = false\n[[endpoints]]\nlisten = "0.0.0.0:1"\nremote = "a.com:2"\n'
                               '[[endpoints]]\nlisten = "[::]:3"\nremote = "b.com:4"\n[endpoints.network]\nuse_udp = true\n')
        self.assertEqual(self.shell('config_tool rows').stdout,
                         '1\t0.0.0.0:1\ta.com:2\t1\ttcp\n2\t[::]:3\tb.com:4\t3\ttcp,udp\n')
        self.assertEqual(self.shell('config_tool protocols').stdout, 'TCP\n')

    def test_overview_before_deploy(self):
        self.write_rules(1)
        out = self.shell('show_overview').stdout
        self.assertIn('未部署', out)
        self.assertIn('0.0.0.0:12000', out)
        self.assertIn('未运行', out)


if __name__ == '__main__':
    unittest.main()
