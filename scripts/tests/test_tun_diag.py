"""Offline regression checks. Run: python scripts/tests/test_tun_diag.py

Uses Python's standard library, Windows PowerShell 5.1 and curl.exe.
The integration run collects local Windows state; all HTTP fixtures bind loopback.
"""

import base64
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import date


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'scripts'
TESTS = Path(__file__).resolve().parent
SECRET = 'diag-test-secret-"quoted"-back\\slash'
ENV_SENTINEL = 'unrelated-environment-value-must-not-appear'


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def powershell(code, *, env=None, timeout=30):
    encoded = base64.b64encode(code.encode('utf-16le')).decode('ascii')
    result = subprocess.run(
        ['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive',
         '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded],
        cwd=ROOT, capture_output=True, env=env, timeout=timeout,
    )
    output = result.stdout.decode('utf-8-sig', errors='replace')
    errors = result.stderr.decode('utf-8-sig', errors='replace')
    if result.returncode:
        raise AssertionError(f'PowerShell exit={result.returncode}\n{output}\n{errors}')
    return output


def library(extra=''):
    return (
        '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); '
        "$ErrorActionPreference = 'Stop'; "
        f'. {ps_quote(SCRIPTS / "tun-diag.ps1")} -NoPause; '
        '$script:DiagWriter = New-Object IO.StringWriter; '
        '$script:DiagCurl = (Get-Command curl.exe).Source; '
        + extra
    )


class Fixture(http.server.BaseHTTPRequestHandler):
    requests = []
    hosts = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        type(self).requests.append((self.path, self.headers.get('Authorization')))
        type(self).hosts.append(self.headers.get('Host'))
        code = 200
        if self.path == '/version':
            body = {'version': 'mock-version', 'meta': True}
        elif self.path == '/configs':
            body = {'mode': 'rule', 'mixed-port': self.server.server_port,
                    'secret': SECRET, 'authentication': ['do-not-log-auth'],
                    'tun': {'enable': True, 'device': '测试网卡', 'stack': 'mixed',
                            'dns-hijack': ['any:53']}}
        elif self.path == '/connections':
            body = {'connections': [{'start': '2026-10-04T00:00:00Z',
                                     'metadata': {'host': 'example.test',
                                                  'destinationIP': '198.18.0.10',
                                                  'process': 'fixture.exe'},
                                     'rule': 'Domain', 'chains': ['测试组']}]}
        elif self.path == '/proxies':
            body = {'proxies': {'group': {'name': '测试组', 'type': 'Selector',
                                          'all': ['one'], 'now': 'one',
                                          'password': 'do-not-log-node-password'}}}
        elif self.path == '/rules':
            body = {'rules': [{'type': 'Domain', 'payload': 'example.test'}]}
        elif self.path == '/unauthorized':
            code, body = 401, {'message': 'Unauthorized'}
        elif self.path == '/invalid':
            body = 'invalid JSON and private body'
        elif self.path == '/slow':
            time.sleep(3)
            body = {'delayed': True}
        elif self.path == '/status501':
            code, body = 501, {'response': True}
        else:
            body = {'path': self.path}
        data = (body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)).encode('utf-8')
        try:
            self.send_response(code)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


class DiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.api = f'http://127.0.0.1:{cls.server.server_port}'

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def test_windows_arguments_utf8_and_stderr(self):
        # Exercises empty arguments, embedded quotes, trailing slashes and a path with spaces.
        with tempfile.TemporaryDirectory(prefix='tun argument ', dir=TESTS) as folder:
            path = Path(folder) / 'argument echo.ps1'
            path.write_text(
                '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); '
                'ConvertTo-Json -InputObject @($args) -Compress; '
                '[Console]::Error.WriteLine("中文错误"); exit 7', encoding='utf-8-sig')
            values = ['', 'with spaces', 'quote"middle', 'C:\\ending\\', '中文']
            code = library(
                '$result = Invoke-DiagProcess -FilePath "$PSHOME\\powershell.exe" '
                f'-Arguments @("-NoProfile", "-File", {ps_quote(path)}, '
                + ', '.join(map(ps_quote, values))
                + ') -TimeoutSeconds 8; $result | ConvertTo-Json -Compress;')
            result = json.loads(powershell(code))
            self.assertEqual(result['ExitCode'], 7)
            self.assertEqual(json.loads(result['StdOut']), values)
            self.assertIn('中文错误', result['StdErr'])

    def test_process_timeout(self):
        result = json.loads(powershell(library(
            '$result = Invoke-DiagProcess "$PSHOME\\powershell.exe" '
            '@("-NoProfile", "-Command", "Start-Sleep -Seconds 10") 1; '
            '$result | ConvertTo-Json -Compress;')))
        self.assertTrue(result['TimedOut'])
        self.assertLess(result['Seconds'], 5)

    def test_stdin_is_utf8_without_bom_across_console_encodings(self):
        payload = 'header = example\n中文'
        for codepage in [437, 65001]:
            with self.subTest(codepage=codepage):
                code = library(
                    '$originalEncoding=[Console]::InputEncoding; try { '
                    f'[Console]::InputEncoding = [Text.Encoding]::GetEncoding({codepage}); '
                    f'$result = Invoke-DiagProcess -FilePath {ps_quote(sys.executable)} '
                    '-Arguments @("-c", "import sys; print(sys.stdin.buffer.read().hex())") '
                    f'-InputText {ps_quote(payload)}; '
                    f'if([Console]::InputEncoding.CodePage -ne {codepage}){{throw "encoding was not restored"}}; '
                    '$result | ConvertTo-Json -Compress; '
                    '} finally { [Console]::InputEncoding=$originalEncoding };')
                result = json.loads(powershell(code))
                self.assertEqual(result['ExitCode'], 0)
                self.assertEqual(bytes.fromhex(result['StdOut'].strip()), payload.encode('utf-8'))

    def test_default_directory_and_local_collector_encoding(self):
        result = json.loads(powershell(library(
            "Invoke-LocalSnapshot 'unicode' '[ordered]@{ name = ''中文网卡'' }'; "
            '[ordered]@{ directory=$OutputDirectory; log=$script:DiagWriter.ToString() } | ConvertTo-Json -Compress;')).splitlines()[-1])
        self.assertEqual(Path(result['directory']), ROOT / 'output' / 'diagnostics' / date.today().isoformat())
        self.assertIn('中文网卡', result['log'])
        self.assertNotIn('CLIXML', result['log'])

    def test_fixed_address_preserves_host(self):
        port = self.server.server_port
        env = dict(os.environ, HTTP_PROXY='http://127.0.0.1:1',
                   ALL_PROXY='http://127.0.0.1:1', NO_PROXY='')
        code = library(
            f'Invoke-HttpProbe "fixed address" "http://entry.invalid:{port}/probe" '
            f'"" @("--resolve", "entry.invalid:{port}:127.0.0.1"); '
            '$script:DiagResults[0] | ConvertTo-Json -Compress;')
        result = json.loads(powershell(code, env=env).splitlines()[-1])
        self.assertEqual(result['Status'], 'RESPONSE')
        self.assertIn(f'entry.invalid:{port}', Fixture.hosts)

    def test_api_auth_bypasses_environment_proxy_and_rejects_bad_json(self):
        env = dict(os.environ, HTTP_PROXY='http://127.0.0.1:1',
                   HTTPS_PROXY='http://127.0.0.1:1', ALL_PROXY='http://127.0.0.1:1', NO_PROXY='')
        code = library(
            f'$Api = {ps_quote(self.api)}; $Secret = {ps_quote(SECRET)}; '
            '$a = Get-ApiSnapshot "/version"; '
            '$b = Get-ApiSnapshot "/unauthorized"; '
            '$c = Get-ApiSnapshot "/invalid"; '
            '[ordered]@{ a=$a; b=$b; c=$c; log=$script:DiagWriter.ToString() } | ConvertTo-Json -Depth 5 -Compress;')
        result = json.loads(powershell(code, env=env))
        self.assertTrue(result['a']['Ok'])
        self.assertEqual(result['b']['HttpCode'], 401)
        self.assertFalse(result['c']['Ok'])
        self.assertIn('[AUTH]', result['log'])
        self.assertNotIn('private body', result['log'])
        self.assertNotIn(SECRET, result['log'])
        self.assertIn(('/version', 'Bearer ' + SECRET), Fixture.requests)

    def test_http_status_and_timeout_classification(self):
        result = json.loads(powershell(library(
            '$RequestTimeoutSeconds = 2; '
            f'Invoke-HttpProbe "application error" {ps_quote(self.api + "/status501")}; '
            f'Invoke-HttpProbe "timeout" {ps_quote(self.api + "/slow")}; '
            'ConvertTo-Json -InputObject $script:DiagResults.ToArray() -Compress;')).splitlines()[-1])
        self.assertEqual(result[0]['Status'], 'RESPONSE')
        self.assertIn('HTTP=501', result[0]['Detail'])
        self.assertEqual(result[1]['Status'], 'TIMEOUT')

    def test_explicit_proxy_ignores_no_proxy(self):
        env = dict(os.environ, NO_PROXY='*')
        code = library(
            f'Invoke-HttpProbe "proxy" "http://target.invalid/probe" {ps_quote(self.api)}; '
            '$script:DiagResults[0] | ConvertTo-Json -Compress;')
        result = json.loads(powershell(code, env=env).splitlines()[-1])
        self.assertEqual(result['Status'], 'RESPONSE')
        self.assertTrue(any(path == 'http://target.invalid/probe' for path, _ in Fixture.requests))

    def test_redaction(self):
        result = powershell(library(
            "$Secret = 'known-secret'; "
            "Protect-DiagText 'http://user:password@proxy:123/?token=hide&x=keep known-secret';"))
        for value in ['user:password', 'token=hide', 'known-secret']:
            self.assertNotIn(value, result)
        self.assertIn('x=keep', result)
        self.assertIn('[REDACTED]', result)

    def test_full_local_collection_with_mock_controller(self):
        env = dict(os.environ, FLCLASH_DIAG_SECRET=SECRET,
                   TUN_DIAG_UNRELATED_SECRET=ENV_SENTINEL,
                   HTTP_PROXY='http://diag-user:diag-password@127.0.0.1:1')
        with tempfile.TemporaryDirectory(prefix='tun report ', dir=TESTS) as folder:
            code = (
                '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); '
                f'& {ps_quote(ROOT / "01-采集当前网络诊断.bat")} -Api {ps_quote(self.api)} '
                f'-OutputDirectory {ps_quote(folder)} -SkipNetworkTests -NoPause; '
                'exit $LASTEXITCODE;')
            powershell(code, env=env, timeout=150)
            logs = list(Path(folder).glob('diag_*.txt'))
            self.assertEqual(len(logs), 1)
            data = logs[0].read_bytes()
            self.assertTrue(data.startswith(b'\xef\xbb\xbf'))
            report = data.decode('utf-8-sig')
            self.assertIn('测试网卡', report)
            self.assertIn('测试组', report)
            self.assertIn('采集汇总', report)
            self.assertIn(f'本次显式代理对照地址: {self.api}', report)
            for forbidden in [ENV_SENTINEL, SECRET, 'do-not-log-auth', 'do-not-log-node-password', 'diag-user:diag-password']:
                self.assertNotIn(forbidden, report)
            self.assertNotIn('[FATAL]', report)
            self.assertNotIn('CLIXML', report)
            self.assertNotIn('\ufffd', report)
            self.assertIn('proxyEnvironment', report)
            self.assertNotIn('百度：系统路由/TUN', report)
            self.assertLess(report.index('API /connections'), report.index('网卡、IP、DNS'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
