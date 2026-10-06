"""Validate portable launchers, isolated outputs and route command boundaries.

Run: python scripts/tests/test_layout.py
Only the mock HTTP controller is contacted. No ETW sessions or routes are changed.
"""
import base64
from datetime import date
import http.server
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import unittest

from test_tun_diag import Fixture

ROOT = Path(__file__).resolve().parents[2]
LAUNCHERS = {
    '01-采集当前网络诊断.bat': 'tun-diag.ps1',
    '02-开始记录路由来源.bat': 'route-origin-trace.ps1',
    '03-停止记录并保存.bat': 'route-origin-trace.ps1',
    '04-生成删除命令.bat': 'generate-route-delete-command.ps1',
}


def q(value):
    return "'" + str(value).replace("'", "''") + "'"


def ps(code, cwd, timeout=120):
    prefix = "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; "
    prefix += '[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false); '
    encoded = base64.b64encode((prefix + code).encode('utf-16le')).decode('ascii')
    result = subprocess.run(
        ['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive',
         '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded],
        cwd=cwd, capture_output=True, timeout=timeout)
    if result.returncode:
        raise AssertionError(result.stdout.decode('utf-8', errors='replace') +
                             result.stderr.decode('utf-8', errors='replace'))
    return result.stdout.decode('utf-8-sig')


class LayoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='tun-layout-')
        self.base = Path(self.temp.name).resolve()
        self.assertTrue(self.base.is_relative_to(Path(tempfile.gettempdir()).resolve()))
        self.tool = self.base / '移动后的工具 with spaces'
        self.scripts = self.tool / 'scripts'
        self.scripts.mkdir(parents=True)
        self.cwd = self.base / 'unrelated working directory'
        self.cwd.mkdir()
        for name, source in LAUNCHERS.items():
            shutil.copy2(ROOT / name, self.tool / name)
            shutil.copy2(ROOT / 'scripts' / source, self.scripts / source)

    def tearDown(self):
        # The cleanup target was resolved and verified beneath the temporary root.
        self.assertTrue(self.base.is_relative_to(Path(tempfile.gettempdir()).resolve()))
        self.temp.cleanup()

    def test_all_launchers_find_their_dependencies(self):
        for name, source in LAUNCHERS.items():
            text = (self.tool / name).read_text(encoding='ascii')
            self.assertIn(f'%~dp0scripts\\{source}', text)
            self.assertIn('-LaunchedFromBatch %*', text)
            self.assertTrue((self.scripts / source).is_file())

    def test_default_diagnostics_output_from_other_working_directory(self):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            ps(f'& {q(self.tool / "01-采集当前网络诊断.bat")} '
               f'-Api http://127.0.0.1:{server.server_port} -SkipNetworkTests -NoPause; '
               'exit $LASTEXITCODE;', self.cwd)
        finally:
            server.shutdown()
            server.server_close()
        logs = list((self.tool / 'output' / 'diagnostics' / date.today().isoformat()).glob('diag_*.txt'))
        self.assertEqual(len(logs), 1)
        self.assertIn('采集汇总', logs[0].read_text(encoding='utf-8-sig'))
        self.assertFalse(list(self.cwd.glob('diag_*.txt')))
        self.assertFalse(list(self.scripts.glob('diag_*.txt')))
        self.assertFalse(list(self.tool.glob('diag_*.txt')))

    def test_generator_default_output_and_stale_command_replacement(self):
        source = self.scripts / 'generate-route-delete-command.ps1'
        result = self.tool / 'output' / 'commands' / 'route-delete-command.txt'
        ps(f'. {q(source)}; '
           'function Get-NetRoute { [CmdletBinding()]param($AddressFamily,$PolicyStore); '
           "[pscustomobject]@{DestinationPrefix='198.18.0.0/24';NextHop='192.168.50.1';InterfaceAlias='Wi-Fi';InterfaceIndex=12} }; "
           'function Get-NetAdapter { [CmdletBinding()]param([switch]$IncludeHidden); '
           '[pscustomobject]@{ifIndex=12;HardwareInterface=$true;Virtual=$false} }; '
           '$status=Start-RouteDeleteCommandGenerator; if($status -ne 0){throw "generator failed"};', self.cwd)
        self.assertIn('192.168.50.1 if 12', result.read_text(encoding='utf-8-sig'))
        ps(f'. {q(source)}; '
           'function Get-NetRoute { [CmdletBinding()]param($AddressFamily,$PolicyStore) }; '
           '$status=Start-RouteDeleteCommandGenerator; if($status -ne 0){throw "empty query failed"};', self.cwd)
        self.assertNotIn('route.exe delete', result.read_text(encoding='utf-8-sig'))
        self.assertFalse((self.scripts / result.name).exists())
        self.assertFalse((self.tool / result.name).exists())

    def test_trace_relative_marker_and_safe_archive(self):
        trace_root = self.tool / 'output' / 'route-traces'
        recording = trace_root / '20990101_120000_abcdef'
        recording.mkdir(parents=True)
        (recording / 'stopped-at.txt').write_text('fixture stop', encoding='utf-8')
        (trace_root / '.active.json').write_text(json.dumps({
            'session': 'FlClashRouteOrigin', 'recording': recording.name,
            'started': '2099-01-01T12:00:00+08:00'}), encoding='utf-8')
        output = ps(f'. {q(self.scripts / "route-origin-trace.ps1")}; '
                    '$saved=Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json; '
                    '$resolved=Get-TraceStateDirectory $saved; '
                    f'if($resolved -ne {q(recording)}){{throw "wrong relocated path"}}; '
                    '$rejected=$false; try { Get-TraceStateDirectory ([pscustomobject]@{recording="..\\escape"}) } '
                    'catch { $rejected=$true }; if(-not $rejected){throw "invalid marker accepted"}; '
                    'Complete-TraceMarker $resolved; Write-Output "OK";', self.cwd)
        self.assertIn('OK', output)
        self.assertTrue((recording / 'trace-info.json').is_file())
        self.assertFalse((trace_root / '.active.json').exists())

    def test_start_stop_launchers_dispatch_without_touching_etw(self):
        # Replace only the temporary dependency with a stub. Native ETW is never started.
        (self.scripts / 'route-origin-trace.ps1').write_text(
            'param([string]$Action,[switch]$LaunchedFromBatch,[switch]$NoPause); '
            'if(-not $LaunchedFromBatch -or -not $NoPause){exit 8}; Write-Output $Action;',
            encoding='utf-8-sig')
        for name, action in [('02-开始记录路由来源.bat', 'Start'), ('03-停止记录并保存.bat', 'Stop')]:
            output = ps(f'& {q(self.tool / name)} -NoPause; exit $LASTEXITCODE;', self.cwd)
            self.assertIn(action, output)

    def test_generator_excludes_direct_virtual_and_other_prefix_routes(self):
        source = self.scripts / 'generate-route-delete-command.ps1'
        result = ps(f'. {q(source)}; '
                    '$adapters=@([pscustomobject]@{ifIndex=12;HardwareInterface=$true;Virtual=$false},'
                    '[pscustomobject]@{ifIndex=30;HardwareInterface=$false;Virtual=$true}); '
                    '$routes=@('
                    "[pscustomobject]@{DestinationPrefix='198.18.0.0/24';NextHop='192.0.2.1';InterfaceIndex=12},"
                    "[pscustomobject]@{DestinationPrefix='198.18.0.0/30';NextHop='192.0.2.1';InterfaceIndex=12},"
                    "[pscustomobject]@{DestinationPrefix='198.18.0.0/24';NextHop='0.0.0.0';InterfaceIndex=12},"
                    "[pscustomobject]@{DestinationPrefix='198.18.0.0/24';NextHop='127.0.0.1';InterfaceIndex=12},"
                    "[pscustomobject]@{DestinationPrefix='198.18.0.0/24';NextHop='198.18.0.2';InterfaceIndex=30},"
                    "[pscustomobject]@{DestinationPrefix='198.18.0.0/24';NextHop='192.0.2.1';InterfaceIndex=99},"
                    "[pscustomobject]@{DestinationPrefix='198.18.0.0/24';NextHop='::1';InterfaceIndex=12}); "
                    '$plans=@(Get-RouteDeletePlan -Routes $routes -Adapters $adapters); '
                    'ConvertTo-Json -InputObject $plans -Compress;', self.cwd)
        plans = json.loads(result)
        self.assertEqual(len(plans), 6)
        self.assertEqual([p['Command'] for p in plans if p['Command']],
                         ['route.exe delete 198.18.0.0 mask 255.255.255.0 192.0.2.1 if 12'])

    def test_document_links_resolve(self):
        for document in [ROOT / 'README.md', *list((ROOT / 'docs').rglob('*.md'))]:
            for target in re.findall(r'\]\(([^)]+)\)', document.read_text(encoding='utf-8-sig')):
                target = target.strip('<>').split('#')[0]
                if not target or re.match(r'^https?://', target):
                    continue
                self.assertTrue((document.parent / target).exists(), f'{document}: {target}')


if __name__ == '__main__':
    unittest.main(verbosity=2)
