"""Offline tests: no host firewall, package manager or /etc mutations."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "l2tp.sh").read_text(encoding="utf-8")
BASH = os.environ.get("TEST_BASH") or shutil.which("bash")
if not BASH and os.name == "nt":
    BASH = r"C:\Program Files\Git\bin\bash.exe"

SETTINGS = r'''
VPN_USER=real
VPN_PASS=Abcdefghijk12345678
IPSEC_PSK=Abcdefghijklmnopqrstuvwxyz1234567
L2TP_PORT=18562
VPN_LOCAL_IP=192.168.18.1
VPN_CIDR=192.168.18.0/24
VPN_IP_RANGE=192.168.18.10-192.168.18.250
FIREWALL_BACKEND=iptables
EGRESS_IF=ens3
'''


def embedded(function):
    body = SCRIPT.split(f"{function}() {{", 1)[1]
    return body.split("<<'PY'\n", 1)[1].split("\nPY", 1)[0]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="l2tp-test-")
        self.work = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def shell(self, code, ok=True):
        env = dict(os.environ, TEST_TMP=str(self.work), TEST_PYTHON=sys.executable)
        # Support Git Bash on Windows without requiring WSL. On Linux this is a no-op.
        prelude = r'''
source ./l2tp.sh
WORK_DIR=$TEST_TMP
if command -v cygpath >/dev/null; then
    WORK_DIR=$(cygpath -u "$TEST_TMP")
    TEST_PYTHON=$(cygpath -u "$TEST_PYTHON")
fi
python3() {
    local arg
    local -a converted=()
    for arg in "$@"; do
        if command -v cygpath >/dev/null && [[ $arg == /* ]]; then
            converted+=("$(cygpath -w "$arg")")
        else
            converted+=("$arg")
        fi
    done
    "$TEST_PYTHON" "${converted[@]}"
}
'''
        result = subprocess.run([BASH, "--noprofile", "--norc", "-s"],
                                input=prelude + SETTINGS + code, text=True,
                                encoding="utf-8", capture_output=True, cwd=ROOT, env=env)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def run_python(self, function, args, prefix=""):
        return subprocess.run([sys.executable, "-c", prefix + embedded(function), *map(str, args)],
                              capture_output=True, text=True, encoding="utf-8",
                              env=dict(os.environ, PYTHONIOENCODING="utf-8"))

    def test_random_credentials(self):
        result = self.shell('for n in {1..100}; do random_secret 18; echo; random_secret 32; echo; done')
        values = result.stdout.splitlines()
        self.assertEqual(len(values), 200)
        self.assertEqual(len(set(values)), 200)
        for i, value in enumerate(values):
            self.assertEqual(len(value), 18 if i % 2 == 0 else 32)
            self.assertRegex(value, r"^[A-Za-z0-9]+$")
            for pattern in (r"[A-Z]", r"[a-z]", r"[0-9]"):
                self.assertRegex(value, pattern)

    def test_empty_defaults_and_psk(self):
        self.shell(r'''
unset VPN_USER VPN_PASS IPSEC_PSK L2TP_PORT
NONINTERACTIVE=1
pick_port() { echo 18562; }
ask_settings
[[ $VPN_USER == real && ${#VPN_PASS} == 18 && ${#IPSEC_PSK} == 32 ]]
[[ $VPN_PASS != "$IPSEC_PSK" && $L2TP_PORT == 18562 ]]
''')

    def test_port_detection_and_selection(self):
        self.shell(r'''
ss() {
    printf '%s\n' 'udp UNCONN 0 0 0.0.0.0:19000 0.0.0.0:*' \
      'tcp LISTEN 0 128 [::]:19001 [::]:*' 'udp ESTAB 0 0 127.0.0.1:99 127.0.0.1:19002'
}
port_busy 19000
port_busy 19001
! port_busy 19002
printf '32768 60999\n' > "$WORK_DIR/ephemeral"
echo 0 > "$WORK_DIR/count"
od() {
    local n
    n=$(cat "$WORK_DIR/count")
    echo "$((n+1))" > "$WORK_DIR/count"
    case $n in 0) echo 30000;; 1) echo 9000;; 2) echo 9001;; *) echo 9002;; esac
}
OLD_PORT=19000
[[ $(pick_port "$WORK_DIR/ephemeral") == 19002 ]]
[[ $(cat "$WORK_DIR/count") == 4 ]]
''')

    def test_input_validation(self):
        for assignment in ("VPN_USER='bad user'", "VPN_USER='--bad'", "VPN_PASS=$'abc\\ndef1234'",
                           "IPSEC_PSK=short", "L2TP_PORT=500", "L2TP_PORT=4500", "L2TP_PORT=65536",
                           "L2TP_PORT=018562"):
            with self.subTest(assignment=assignment):
                self.shell(assignment + "\nvalidate_values", ok=False)

    def test_secret_escaping_and_roundtrip(self):
        secret = 'Sp ace"quote\\back$()`tick#123'
        self.shell("VPN_PASS=" + shlex.quote(secret) + "\nIPSEC_PSK=$VPN_PASS\n" + r'''
render_configs "$WORK_DIR/render"
save_config "$WORK_DIR/config"
stat() { if [[ $2 == %u ]]; then echo 0; else echo 600; fi; }
original=$VPN_PASS
VPN_PASS=changed
load_config "$WORK_DIR/config"
[[ $VPN_PASS == "$original" && $IPSEC_PSK == "$original" ]]
''')
        fields = shlex.split((self.work / "render/chap-secrets").read_text())
        self.assertEqual(fields, ["real", "*", secret, "*"])
        psk = (self.work / "render/ipsec.secrets").read_text().strip().split()[-1]
        self.assertEqual(bytes.fromhex(psk[2:]).decode(), secret)
        self.assertIn("leftprotoport=17/18562", (self.work / "render/ipsec.conf").read_text())
        self.assertNotIn("ipsec saref", (self.work / "render/xl2tpd.conf").read_text())

    def test_insecure_state_is_rejected(self):
        self.shell(r'''
save_config "$WORK_DIR/config"
stat() { if [[ $2 == %u ]]; then echo 0; else echo 644; fi; }
load_config "$WORK_DIR/config"
''', ok=False)

    def test_rerun_and_reconfigure(self):
        for reconfigure in (False, True):
            with self.subTest(reconfigure=reconfigure):
                self.shell(r'''
CONFIG_FILE=$WORK_DIR/config
save_config "$CONFIG_FILE"
unset VPN_USER VPN_PASS IPSEC_PSK L2TP_PORT VPN_CIDR VPN_LOCAL_IP VPN_IP_RANGE FIREWALL_BACKEND
NONINTERACTIVE=1
stat() { if [[ $2 == %u ]]; then echo 0; else echo 600; fi; }
preflight() { :; }
detect_existing() { :; }
detect_backend() { :; }
install_packages() { :; }
detect_egress() { :; }
validate_network() { :; }
port_busy() { return 1; }
pick_port() { echo 18563; }
backup_files() { :; }
install_configs() { save_config "$CONFIG_FILE"; }
install_services() { :; }
show_result() { :; }
''' + ("VPN_USER=override\nmain\n[[ $VPN_USER == real && $L2TP_PORT == 18562 && $VPN_PASS == Abcdefghijk12345678 ]]"
       if not reconfigure else
       "main --reconfigure\n[[ $VPN_USER == real && $L2TP_PORT == 18563 && ${#VPN_PASS} == 18 && ${#IPSEC_PSK} == 32 ]]\n[[ $VPN_PASS != Abcdefghijk12345678 ]]"))

    def test_routes_and_address_pool(self):
        routes = self.work / "routes.json"
        routes.write_text(json.dumps([{"dst": "default", "dev": "ens3"}, {"dst": "10.0.0.0/24", "dev": "ens3"}]))
        args = ["192.168.18.0/24", "192.168.18.1", "192.168.18.10-192.168.18.250", routes]
        self.assertEqual(self.run_python("validate_network", args).returncode, 0)
        for changed in (["192.168.18.0/24", "192.168.18.1", "192.168.18.1-192.168.18.20", routes],
                        ["127.0.0.0/24", "127.0.0.1", "127.0.0.10-127.0.0.20", routes],
                        ["10.0.0.0/24", "10.0.0.1", "10.0.0.10-10.0.0.20", routes],
                        ["192.168.18.0/24", "192.168.19.1", "192.168.18.10-192.168.18.20", routes]):
            self.assertNotEqual(self.run_python("validate_network", changed).returncode, 0)
        routes.write_text(json.dumps([{"dst": "192.168.18.20", "dev": "ppp0"}]))
        self.assertEqual(self.run_python("validate_network", args).returncode, 0)

    def test_legacy_import_and_ambiguity(self):
        files = {"/etc/ppp/chap-secrets": 'olduser * OldPass123! *\n',
                 "/etc/ipsec.secrets": ': PSK "OldPSK123!"\n',
                 "/etc/xl2tpd/xl2tpd.conf": '[global]\n[lns default]\nip range = 192.168.18.0/24\nlocal ip = 192.168.18.1\n'}
        prefix = 'import pathlib\nfiles=' + repr(files) + '\npathlib.Path.read_text=lambda self: files[str(self).replace("\\\\", "/")]\n'
        # write_text is real; read_text alone redirects the old /etc fixture.
        target = self.work / "import"
        self.assertEqual(self.run_python("import_legacy", [target], prefix).returncode, 0)
        self.assertIn("VPN_IP_RANGE=192.168.18.10-192.168.18.250", target.read_text())
        files["/etc/ppp/chap-secrets"] += 'second * AnotherPass1 *\n'
        prefix = 'import pathlib\nfiles=' + repr(files) + '\npathlib.Path.read_text=lambda self: files[str(self).replace("\\\\", "/")]\n'
        self.assertNotEqual(self.run_python("import_legacy", [target], prefix).returncode, 0)

    def test_legacy_psk_is_rotated(self):
        self.shell(r'''
CONFIG_FILE=$WORK_DIR/config
NONINTERACTIVE=1
preflight() { :; }
detect_existing() { LEGACY=1; }
install_packages() { :; }
import_legacy() { IPSEC_PSK=OldPSK123; }
detect_egress() { :; }
validate_network() { :; }
backup_files() { :; }
install_configs() { :; }
install_services() { :; }
show_result() { :; }
main
[[ ${#IPSEC_PSK} == 32 && $IPSEC_PSK != OldPSK123 ]]
''')

    def test_configuration_failure_restores_backup(self):
        result = self.shell(r'''
fixture=$WORK_DIR/restore-target
backup_root=$WORK_DIR/backups
printf original > "$fixture"
CONFIG_FILE=$WORK_DIR/config
RUNTIME=$WORK_DIR/runtime
NONINTERACTIVE=1
preflight() { :; }
detect_existing() { :; }
install_packages() { :; }
detect_egress() { :; }
validate_network() { :; }
port_busy() { return 1; }
backup_files() {
    BACKUP_DIR=$backup_root
    mkdir -p "$BACKUP_DIR/files$(dirname "$fixture")"
    cp "$fixture" "$BACKUP_DIR/files$fixture"
    printf '%s\n' "$fixture" > "$BACKUP_DIR/manifest"
    CHANGED=1
}
install_configs() { printf changed > "$fixture"; return 37; }
systemctl() { :; }
remove_owned_firewall() { :; }
main
''', ok=False)
        self.assertEqual(result.returncode, 37)
        self.assertEqual((self.work / "restore-target").read_text(), "original")
        self.assertNotIn("服务端安装及本机检查完成", result.stdout)

    def test_mirror_retry_limit_and_recovery(self):
        self.shell(r'''
CODENAME=noble
apt_options
timeout() { shift; "$@"; }
sleep() { :; }
apt-get() {
    printf '%s\n' "${*: -1}" >> "$WORK_DIR/calls"
    local count
    count=$(wc -l < "$WORK_DIR/calls")
    ((count >= 3))
}
try_mirror https://example.invalid/ubuntu https://example.invalid/ubuntu
[[ $(wc -l < "$WORK_DIR/calls") == 4 ]]
: > "$WORK_DIR/calls"
apt-get() { echo fail >> "$WORK_DIR/calls"; return 1; }
! try_mirror https://example.invalid/ubuntu https://example.invalid/ubuntu
[[ $(wc -l < "$WORK_DIR/calls") == 3 ]]
''')

    def test_mirror_fallback_and_architecture(self):
        for arch, expected in (("amd64", "http://archive.ubuntu.com/ubuntu"), ("arm64", "http://ports.ubuntu.com/ubuntu-ports")):
            with self.subTest(arch=arch):
                self.shell(f"ARCH={arch}\nCODENAME=noble\n" + r'''
create_package_policy() { :; }
finish_package_install() { :; }
probe_mirror() { return 1; }
try_mirror() { echo "$1 $2" >> "$WORK_DIR/mirrors"; [[ $1 == http://* ]]; }
install_packages
[[ $(wc -l < "$WORK_DIR/mirrors") == 4 ]]
''' + f'[[ $(tail -n1 "$WORK_DIR/mirrors") == {expected}* ]]')
                (self.work / "mirrors").unlink()

    def test_ufw_merge_is_idempotent_and_preserves_ssh(self):
        original = '*filter\n:ufw-before-input - [0:0]\n:ufw-before-forward - [0:0]\n-A ufw-before-input -p tcp --dport 22 -j ACCEPT\nCOMMIT\n*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.0.0.0/24 -j MASQUERADE\nCOMMIT\n'
        (self.work / "before.rules").write_text(original)
        self.shell(r'''
render_ufw "$WORK_DIR/before.rules" "$WORK_DIR/once.rules"
render_ufw "$WORK_DIR/once.rules" "$WORK_DIR/twice.rules"
cmp "$WORK_DIR/once.rules" "$WORK_DIR/twice.rules"
L2TP_PORT=18563
render_ufw "$WORK_DIR/twice.rules" "$WORK_DIR/new.rules"
''')
        text = (self.work / "new.rules").read_text()
        self.assertEqual(text.count("# BEGIN L2TP-INSTALLER"), 2)
        self.assertNotIn("18562", text)
        self.assertIn("--dport 18563 -m policy --dir in --pol ipsec -j ACCEPT", text)
        self.assertIn("--dport 18563 -j DROP", text)
        self.assertIn("--dport 22 -j ACCEPT", text)
        self.assertIn("-s 10.0.0.0/24 -j MASQUERADE", text)
        self.assertLess(text.index("-j L2TP-IN"), text.index("--dport 22"))

    def test_iptables_repeated_apply_and_reconfigure(self):
        state = {"filter": {"INPUT": ["-p tcp --dport 22 -j ACCEPT", "-j DROP"], "FORWARD": ["-j DOCKER"], "DOCKER": []},
                 "nat": {"POSTROUTING": ["-s 10.0.0.0/24 -j MASQUERADE"]}}
        (self.work / "fw.json").write_text(json.dumps(state))
        self.shell(r'''
iptables() { python3 tests/fake_iptables.py "$WORK_DIR/fw.json" command "$@"; }
iptables-restore() { python3 tests/fake_iptables.py "$WORK_DIR/fw.json" restore "$@"; }
apply_iptables
apply_iptables
L2TP_PORT=18563
apply_iptables
''')
        result = json.loads((self.work / "fw.json").read_text())
        self.assertEqual(result["filter"]["INPUT"], ["-j L2TP-IN", *state["filter"]["INPUT"]])
        self.assertEqual(result["filter"]["FORWARD"], ["-j L2TP-FWD", "-j DOCKER"])
        self.assertEqual(result["nat"]["POSTROUTING"], ["-j L2TP-NAT", *state["nat"]["POSTROUTING"]])
        rules = "\n".join(result["filter"]["L2TP-IN"])
        self.assertNotIn("18562", rules)
        self.assertIn("--dport 18563 -j DROP", rules)
        self.assertEqual(len(result["filter"]["L2TP-IN"]), 4)


if __name__ == "__main__":
    unittest.main()
