import unittest
from pathlib import Path

from jinja2 import Environment


class OpenWebUINginxListenerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(
            "ansible/roles/open_webui_reverse_proxy/templates/"
            "nginx-site.conf.j2"
        )
        cls.source = path.read_text()
        cls.template = Environment(
            autoescape=False,
            keep_trailing_newline=True,
        ).from_string(cls.source)

    def render(self, listen_ips):
        return self.template.render(
            open_webui_proxy_listen_ips=listen_ips,
            open_webui_proxy_domain="chat.example.test",
            open_webui_proxy_certificate_dir="/tmp/test-certificate",
            open_webui_proxy_backend="http://127.0.0.1:3000",
        )

    def test_http_and_https_listen_on_lan_and_tailscale(self):
        rendered = self.render(["192.0.2.10", "198.51.100.20"])

        for address in ("192.0.2.10", "198.51.100.20"):
            self.assertIn(f"listen {address}:80;", rendered)
            self.assertIn(f"listen {address}:443 ssl;", rendered)

    def test_duplicate_addresses_render_only_once(self):
        rendered = self.render(["192.0.2.10"])

        self.assertEqual(rendered.count("listen 192.0.2.10:80;"), 1)
        self.assertEqual(rendered.count("listen 192.0.2.10:443 ssl;"), 1)

    def test_backend_and_websocket_configuration_remain(self):
        rendered = self.render(["192.0.2.10", "198.51.100.20"])

        self.assertIn("proxy_pass http://127.0.0.1:3000;", rendered)
        self.assertIn("proxy_set_header Upgrade", rendered)
        self.assertIn('proxy_set_header Connection "upgrade";', rendered)
        self.assertIn("ssl_certificate_key", rendered)
        self.assertIn("http2 on;", rendered)

    def test_template_uses_dynamic_listener_variable(self):
        self.assertIn("open_webui_proxy_listen_ips", self.source)
        self.assertNotIn("open_webui_proxy_tailscale_ip }}:80", self.source)
        self.assertNotIn(
            "open_webui_proxy_tailscale_ip }}:443",
            self.source,
        )
        self.assertNotIn("192.168.1.10", self.source)
        self.assertNotIn("100.64.72.58", self.source)


if __name__ == "__main__":
    unittest.main()
