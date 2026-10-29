import unittest
from pathlib import Path

from jinja2 import Environment


class OllamaAPINginxListenerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(
            "ansible/roles/open_webui_reverse_proxy/templates/"
            "ollama-api-site.conf.j2"
        )
        cls.template = Environment(
            autoescape=False,
            keep_trailing_newline=True,
        ).from_string(path.read_text())

    def render(self, listen_ips):
        return self.template.render(
            open_webui_proxy_ollama_listen_ips=listen_ips,
            open_webui_proxy_ollama_domain="ollama.example.test",
            open_webui_proxy_ollama_certificate_dir="/tmp/test-certificate",
            open_webui_proxy_ollama_backend="http://127.0.0.1:11434",
        )

    def test_http_and_https_listen_on_lan_and_tailscale(self):
        rendered = self.render(["192.0.2.10", "198.51.100.20"])

        for address in ("192.0.2.10", "198.51.100.20"):
            self.assertIn(f"listen {address}:80;", rendered)
            self.assertIn(f"listen {address}:443 ssl;", rendered)

    def test_duplicate_addresses_render_only_one_listener_each(self):
        rendered = self.render(["192.0.2.10"])

        self.assertEqual(rendered.count("listen 192.0.2.10:80;"), 1)
        self.assertEqual(rendered.count("listen 192.0.2.10:443 ssl;"), 1)

    def test_backend_and_authentication_remain_configured(self):
        rendered = self.render(["192.0.2.10", "198.51.100.20"])

        self.assertIn("proxy_pass http://127.0.0.1:11434;", rendered)
        self.assertIn("if ($ollama_api_authorized = 0)", rendered)
        self.assertIn('return 401;', rendered)
        self.assertIn('proxy_set_header Authorization "";', rendered)

    def test_template_does_not_hardcode_listener_addresses(self):
        source = Path(
            "ansible/roles/open_webui_reverse_proxy/templates/"
            "ollama-api-site.conf.j2"
        ).read_text()

        self.assertIn("open_webui_proxy_ollama_listen_ips", source)
        self.assertNotIn("192.168.1.10", source)
        self.assertNotIn("100.64.72.58", source)


if __name__ == "__main__":
    unittest.main()
