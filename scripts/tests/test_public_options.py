"""Check optional probe targets without contacting external networks."""
import json
import unittest

from test_tun_diag import SCRIPTS, library, powershell, ps_quote


def probe_plan(options=''):
    code = library(
        '$script:Seen = New-Object "System.Collections.Generic.List[object]"; '
        'function Write-DiagSection { param($Title) }; '
        'function Invoke-LocalSnapshot { param($Name,$Code,$TimeoutSeconds) }; '
        'function Invoke-DnsProbe { param($Name,$Server=""); '
        '$script:Seen.Add([pscustomobject]@{kind="dns";server=$Server}) }; '
        'function Invoke-HttpProbe { param($Name,$Url,$ViaProxy="",$ExtraArguments=@()); '
        '$script:Seen.Add([pscustomobject]@{kind="http";url=$Url;extra=@($ExtraArguments)}) }; '
        + options + '; Write-NetworkProbes; '
        'ConvertTo-Json -InputObject $script:Seen.ToArray() -Depth 4 -Compress;')
    return json.loads(powershell(code))


class PublicOptionsTests(unittest.TestCase):
    def test_default_has_no_personal_or_optional_probe_target(self):
        plan = probe_plan()
        self.assertEqual([p['server'] for p in plan if p['kind'] == 'dns'],
                         ['', '223.5.5.5'])
        self.assertEqual({p['url'] for p in plan if p['kind'] == 'http'},
                         {'https://www.baidu.com', 'https://www.google.com'})

    def test_domain_only_and_fixed_ipv6_probes(self):
        domain_only = probe_plan("$EntryDomain='entry.example'")
        entries = [p for p in domain_only if p.get('url') == 'https://entry.example']
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['extra'], [])
        fixed = probe_plan("$EntryDomain='entry.example'; $EntryIP='2001:db8::10'; "
                           "$DnsServer='192.0.2.53'")
        entries = [p for p in fixed if p.get('url') == 'https://entry.example']
        self.assertEqual(len(entries), 2)
        self.assertEqual(entries[1]['extra'],
                         ['--resolve', 'entry.example:443:[2001:db8::10]'])
        self.assertIn('192.0.2.53', [p['server'] for p in fixed if p['kind'] == 'dns'])

    def test_invalid_options_fail_before_collecting(self):
        for arguments in ["-EntryIP '192.0.2.10'", "-DnsServer 'bad-address'",
                          "-EntryDomain 'https://entry.example'",
                          "-EntryDomain 'entry.example' -EntryIP 'bad-address'"]:
            with self.subTest(arguments=arguments):
                code = ('[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false); '
                        f'. {ps_quote(SCRIPTS / "tun-diag.ps1")} {arguments} -NoPause; '
                        'function Write-CoreSnapshots { throw "unexpected collection" }; '
                        '$result=Start-TunDiagnostics; Write-Output $result;')
                output = powershell(code)
                self.assertEqual(output.strip().splitlines()[-1], '1')
                self.assertNotIn('unexpected collection', output)

    def test_legacy_dns_parameter_alias(self):
        code = (f'. {ps_quote(SCRIPTS / "tun-diag.ps1")} -CampusDns 192.0.2.53; '
                'Write-Output $DnsServer;')
        self.assertEqual(powershell(code).strip(), '192.0.2.53')


if __name__ == '__main__':
    unittest.main(verbosity=2)
