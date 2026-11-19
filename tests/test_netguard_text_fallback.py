"""nft < 0.9（CentOS 7 是 0.8）没有 -j：netguard 必须能用文本输出工作。"""

from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "netguard"))
import netguard  # noqa: E402

TABLE_TEXT = '''table inet nodelite_netguard {
\tset devices_12_v4 {
\t\ttype ipv4_addr
\t\tsize 65535
\t\tflags dynamic,timeout
\t\ttimeout 15s
\t\telements = { 1.2.3.4 timeout 15s expires 14s899ms,
\t\t\t     5.6.7.8 timeout 15s expires 12s100ms }
\t}

\tset devices_12_v6 {
\t\ttype ipv6_addr
\t\tsize 65535
\t\tflags dynamic,timeout
\t\ttimeout 15s
\t\telements = { 2001:db8::1 timeout 15s expires 14s }
\t}

\tchain input {
\t\ttype filter hook input priority -5; policy accept;
\t\ttcp dport 20000 ip saddr @devices_12_v4 accept comment "nodelite-node-12-ipv4-accept"
\t\ttcp dport 20000 ip saddr @devices_12_v4 reject with tcp reset comment "nodelite-node-12-ipv4-reject"
\t\ttcp dport 20000 ip6 saddr @devices_12_v6 accept comment "nodelite-node-12-ipv6-accept"
\t\ttcp dport 20000 ip6 saddr @devices_12_v6 reject with tcp reset comment "nodelite-node-12-ipv6-reject"
\t}
}
'''


@pytest.fixture()
def table(monkeypatch):
    monkeypatch.setattr(netguard, "_nft_table_text", lambda: TABLE_TEXT)
    return TABLE_TEXT


def test_iter_text_sets_and_elements():
    blocks = dict(netguard.iter_text_sets(TABLE_TEXT))
    assert set(blocks) == {"devices_12_v4", "devices_12_v6"}
    assert netguard.text_set_elements(blocks["devices_12_v4"]) == [
        "1.2.3.4", "5.6.7.8",
    ]
    assert netguard.text_set_elements(blocks["devices_12_v6"]) == ["2001:db8::1"]


def test_installed_sources_reads_text_without_json(table, monkeypatch):
    monkeypatch.setattr(netguard, "nft_json_supported", lambda: False)
    sources = netguard.installed_sources([(12, 20000, 100)])
    assert sources[20000] == {"1.2.3.4", "5.6.7.8", "2001:db8::1"}


def test_text_validation_accepts_matching_table(table):
    netguard._validate_text_installed([(12, 20000, 65535)])


def test_text_validation_rejects_stale_node(table):
    with pytest.raises(netguard.InstalledMismatch):
        netguard._validate_text_installed([(13, 20001, 65535)])


def test_text_validation_rejects_wrong_size(table):
    with pytest.raises(netguard.InstalledMismatch):
        netguard._validate_text_installed([(12, 20000, 100)])


def test_text_validation_rejects_missing_reject_rule(monkeypatch):
    broken = TABLE_TEXT.replace(
        '\t\ttcp dport 20000 ip saddr @devices_12_v4 reject with tcp reset comment "nodelite-node-12-ipv4-reject"\n',
        "",
    )
    monkeypatch.setattr(netguard, "_nft_table_text", lambda: broken)
    with pytest.raises(netguard.InstalledMismatch):
        netguard._validate_text_installed([(12, 20000, 65535)])
