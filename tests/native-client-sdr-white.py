#!/usr/bin/env python3
"""Compile the actual Hyprland patch's client-white policy in a small harness."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
patch = (root / "guest/patches/hyprland/client-sdr-white.patch").read_text()
added = "\n".join(line[1:] for line in patch.splitlines() if line.startswith("+") and not line.startswith("+++"))
method = re.search(r"NColorManagement::PImageDescription CMonitor::getClientImageDescription\(\) const \{.*?^\}", added, re.S | re.M)
assert method, "client SDR-white implementation is missing"
source = r"""
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
namespace NColorManagement {
enum Transfer { SDR, CM_TRANSFER_FUNCTION_ST2084_PQ };
struct Luminances { float min = 0; uint32_t max = 993, reference = 203; };
struct Value { Transfer transferFunction = CM_TRANSFER_FUNCTION_ST2084_PQ; struct { bool present = false; } icc; Luminances luminances; };
struct Description {
    Value data;
    const Value& value() const { return data; }
    std::shared_ptr<Description> with(Luminances luminances) const {
        auto copy = std::make_shared<Description>(*this); copy->data.luminances = luminances; return copy;
    }
};
using PImageDescription = std::shared_ptr<Description>;
}
struct CMonitor {
    NColorManagement::PImageDescription m_imageDescription = std::make_shared<NColorManagement::Description>();
    int m_sdrMaxLuminance = 600;
    float m_sdrBrightness = 1;
    NColorManagement::PImageDescription getClientImageDescription() const;
};
""" + method[0] + r"""
int main() {
    CMonitor monitor;
    const auto original = monitor.m_imageDescription;
    for (int white : {80, 100, 250, 500, 600}) {
        monitor.m_sdrMaxLuminance = white;
        auto client = monitor.getClientImageDescription();
        assert(client->value().luminances.reference == static_cast<uint32_t>(white));
        assert(client->value().luminances.max == 993);
        assert(client->value().transferFunction == NColorManagement::CM_TRANSFER_FUNCTION_ST2084_PQ);
        assert(monitor.m_imageDescription == original && original->value().luminances.reference == 203);
    }
    monitor.m_sdrBrightness = 1.25f;
    assert(monitor.getClientImageDescription()->value().luminances.reference == 750);
    monitor.m_sdrBrightness = 10;
    assert(monitor.getClientImageDescription()->value().luminances.reference == 993);
    for (float brightness : {0.f, -1.f, std::numeric_limits<float>::infinity(), std::numeric_limits<float>::quiet_NaN()}) {
        monitor.m_sdrBrightness = brightness;
        assert(monitor.getClientImageDescription()->value().luminances.reference == 600);
    }
    monitor.m_sdrBrightness = 1;
    monitor.m_sdrMaxLuminance = 0;
    assert(monitor.getClientImageDescription() == original);
    monitor.m_sdrMaxLuminance = -1;
    assert(monitor.getClientImageDescription() == original);
    monitor.m_sdrMaxLuminance = 600;
    original->data.transferFunction = NColorManagement::SDR;
    assert(monitor.getClientImageDescription() == original);
    original->data.transferFunction = NColorManagement::CM_TRANSFER_FUNCTION_ST2084_PQ;
    original->data.icc.present = true;
    assert(monitor.getClientImageDescription() == original);
}
"""
compiler = shutil.which("c++")
assert compiler, "a C++20 compiler is required"
with tempfile.TemporaryDirectory(prefix="omarchy-client-sdr-white-") as directory:
    directory = Path(directory)
    (directory / "test.cpp").write_text(source)
    subprocess.run([compiler, "-std=c++20", "-Wall", "-Wextra", "-Werror", str(directory / "test.cpp"), "-o", str(directory / "test")], check=True)
    subprocess.run([str(directory / "test")], check=True)
print("PASS: client SDR white follows the display policy; HDR render description and SDR/ICC modes are preserved")
