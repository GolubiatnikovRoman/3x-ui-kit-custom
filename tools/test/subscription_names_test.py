"""Регрессионные тесты персонализации подписок: python3 tools/test/subscription_names_test.py"""
import base64
import importlib.util
import json
import os
import tempfile
import unittest
from urllib.parse import unquote, urlsplit

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEMP = tempfile.TemporaryDirectory()
CONFIG = os.path.join(TEMP.name, "config.json")
with open(CONFIG, "w", encoding="utf-8") as f:
    json.dump({"path": "/sub/", "upstream": "http://127.0.0.1:1"}, f)
os.environ["KIT_SUB_CONFIG"] = CONFIG
os.environ["KIT_SUB_RULES"] = os.path.join(TEMP.name, "rules.yaml")
spec = importlib.util.spec_from_file_location("kit_sub", os.path.join(ROOT, "scripts", "kit-sub.py"))
ks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ks)


class SubscriptionNames(unittest.TestCase):
    def test_default_preserves_exact_bytes(self):
        for mime, raw in (
            ("text/plain", b"vless://id@example.com:443#REALITY-alex\n"),
            ("application/json", b'{"outbounds":[{"tag":"REALITY-alex"}]}\n'),
            ("text/yaml", b"proxies:\n- name: REALITY-alex\n  type: vless\n"),
        ):
            with self.subTest(mime=mime):
                self.assertIs(ks.apply_names(raw, {"content-type": mime}, "Home", "default"), raw)
                self.assertIs(ks.apply_names(raw, {"content-type": mime}, "", "prefix"), raw)

    def test_vless_link_preserves_connection_parameters(self):
        src = b"vless://uuid@example.com:443?security=reality&pbk=abc&fp=firefox#REALITY-alex"
        out = ks.apply_names(src, {"content-type": "text/plain"}, "Home", "prefix")
        old, new = urlsplit(src.decode()), urlsplit(out.decode())
        self.assertEqual((new.scheme, new.netloc, new.path, new.query),
                         (old.scheme, old.netloc, old.path, old.query))
        self.assertEqual(unquote(new.fragment), "Home • REALITY")

    def test_base64_links_and_unknown_remarks(self):
        plain = "vless://id@host:443#XHTTP-alex\nvless://id@host:443#Other-custom"
        encoded = base64.b64encode(plain.encode())
        out = ks.apply_names(encoded, {"content-type": "text/plain"}, "Дом", "prefix")
        self.assertIn("Дом • XHTTP", base64.b64decode(out).decode())
        self.assertIn("#Other-custom", base64.b64decode(out).decode())

    def test_vmess_name_changes_without_changing_server(self):
        obj = {"v": "2", "ps": "VMess-WS-alex", "add": "example.com", "id": "uuid", "port": "443"}
        src = "vmess://" + base64.b64encode(json.dumps(obj).encode()).decode()
        out = ks.apply_names(src.encode(), {"content-type": "text/plain"}, "Office", "prefix")
        updated = json.loads(base64.b64decode(out.decode()[8:]))
        self.assertEqual(updated["ps"], "Office • VMess-WS")
        self.assertEqual(updated["id"], obj["id"])
        self.assertEqual(updated["add"], obj["add"])

    def test_clash_proxy_and_groups(self):
        cfg = {"proxies": [{"name": "REALITY-alex", "type": "vless", "server": "host", "uuid": "id"},
                           {"name": "XHTTP-alex", "type": "vless", "server": "host2", "uuid": "id2"}],
               "proxy-groups": [{"name": "Select", "type": "select", "proxies": ["REALITY-alex", "XHTTP-alex", "DIRECT"]}],
               "rules": ["MATCH,REALITY-alex"]}
        out = yaml.safe_load(ks.apply_names(yaml.safe_dump(cfg).encode(), {"content-type": "application/yaml"},
                                           "Home", "prefix"))
        self.assertEqual([p["name"] for p in out["proxies"]], ["Home • REALITY", "Home • XHTTP"])
        self.assertEqual(out["proxy-groups"][0]["proxies"], ["Home • REALITY", "Home • XHTTP", "DIRECT"])
        self.assertEqual(out["rules"], ["MATCH,Home • REALITY"])
        self.assertEqual(out["proxies"][0]["uuid"], "id")

    def test_json_outbound_and_routing(self):
        cfg = {"outbounds": [{"tag": "REALITY-alex", "protocol": "vless",
                              "settings": {"vnext": [{"address": "host", "users": [{"id": "uuid"}]}]}}],
               "routing": {"rules": [{"type": "field", "outboundTag": "REALITY-alex"}]}}
        raw = json.dumps(cfg).encode()
        out = json.loads(ks.apply_names(raw, {"content-type": "application/json"}, "Дом", "prefix"))
        self.assertEqual(out["outbounds"][0]["tag"], "Дом • REALITY")
        self.assertEqual(out["routing"]["rules"][0]["outboundTag"], "Дом • REALITY")
        self.assertEqual(out["outbounds"][0]["settings"], cfg["outbounds"][0]["settings"])

    def test_unknown_formats_unchanged(self):
        raw = b"<html>REALITY-alex</html>"
        self.assertIs(ks.apply_names(raw, {"content-type": "text/html"}, "Home", "prefix"), raw)

    def test_invalid_modes_unchanged(self):
        raw = b"vless://id@host:443#REALITY-user"
        self.assertIs(ks.apply_names(raw, {"content-type": "text/plain"}, "Home", "unexpected"), raw)

    def test_idempotence(self):
        src = b"vless://uuid@example.com:443#REALITY-alex"
        headers = {"content-type": "text/plain"}
        once = ks.apply_names(src, headers, "Home", "prefix")
        self.assertEqual(ks.apply_names(once, headers, "Home", "prefix"), once)


if __name__ == "__main__":
    unittest.main()
