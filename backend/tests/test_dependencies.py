"""The Linux image must get the CPU-only torch build, never the CUDA one."""

import pathlib
import tomllib

LOCK = pathlib.Path(__file__).resolve().parent.parent / "poetry.lock"


def _locked(name):
    return [p for p in tomllib.loads(LOCK.read_text())["package"] if p["name"] == name]


def test_linux_torch_is_the_cpu_wheel():
    linux = [p for p in _locked("torch") if p.get("markers") == 'sys_platform == "linux"']
    assert len(linux) == 1
    assert linux[0]["version"].endswith("+cpu")
    assert linux[0]["source"]["url"] == "https://download.pytorch.org/whl/cpu"
    assert "nvidia-cublas-cu12" not in linux[0].get("dependencies", {})
    assert "triton" not in linux[0].get("dependencies", {})


def test_macos_torch_still_resolves():
    others = [p for p in _locked("torch") if p.get("markers") == 'sys_platform != "linux"']
    assert len(others) == 1
    assert any("macosx" in f["file"] for f in others[0]["files"])
