#!/usr/bin/env python3
"""
KRubus Raspberry Pi 5 / CM5 Hardware Patch for KDE ksystemstats:
1. Fix fatal 100%-CPU infinite loop in LinuxCpuPluginPrivate (/proc/cpuinfo EOF after 'Model : Raspberry Pi 5...')
2. Add ARM64 / Raspberry Pi 5 'cpu_thermal' / 'bcm2835_thermal' CPU temperature sensor support + initial scaling_cur_freq
3. Fix Solid DisksPlugin filtering out microSD/eMMC (SdMmc) and USB flash drives (only exclude optical CdromDrive)
4. Add native Broadcom VideoCore VII (V3D) GPU utilization (gpu_stats) & temperature support in LinuxBackend
"""

import os
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "."


def patch_file(rel_path, transform_fn):
    path = os.path.join(root, rel_path)
    if not os.path.isfile(path):
        raise FileNotFoundError(f"Expected file not found: {path}")
    with open(path, "r", encoding="utf-8") as f:
        orig = f.read()
    updated = transform_fn(orig)
    if updated == orig:
        print(f"[patch-ksystemstats-pi5] Already patched or unchanged: {rel_path}")
        return
    with open(path, "w", encoding="utf-8") as f:
        f.write(updated)
    print(f"[patch-ksystemstats-pi5] Patched: {rel_path}")


# 1. Fix /proc/cpuinfo infinite loop + add Raspberry Pi cpu_thermal support
def patch_linux_cpu_plugin(src: str) -> str:
    old_loop = 'for (; line != "\\n";  line = cpuinfo.readLine()) {'
    alt_loop = 'for (; line != "\\n"; line = cpuinfo.readLine()) {'
    new_loop = 'for (; !line.isEmpty() && line != "\\n"; line = cpuinfo.readLine()) {'
    if old_loop in src:
        src = src.replace(old_loop, new_loop, 1)
    elif alt_loop in src:
        src = src.replace(alt_loop, new_loop, 1)
    elif new_loop not in src:
        raise RuntimeError("Could not find /proc/cpuinfo inner loop in linuxcpuplugin.cpp")

    amd_branch = """        } else if (qstrcmp(chipName->prefix, "k10temp") == 0) {
            addSensorsAmd(chipName);
        }"""
    arm_branch = """        } else if (qstrcmp(chipName->prefix, "k10temp") == 0) {
            addSensorsAmd(chipName);
        } else if (qstrcmp(chipName->prefix, "cpu_thermal") == 0 || qstrcmp(chipName->prefix, "bcm2835_thermal") == 0) {
            int featureNumber = 0;
            while (sensors_feature const * feature = sensors_get_features(chipName, &featureNumber)) {
                if (feature->type == SENSORS_FEATURE_TEMP) {
                    for (auto *cpu : std::as_const(m_cpus)) {
                        cpu->makeTemperatureSensor(chipName, feature);
                    }
                    break;
                }
            }
        }"""
    if "cpu_thermal" not in src:
        if amd_branch not in src:
            raise RuntimeError("Could not find addSensors() branch in linuxcpuplugin.cpp")
        src = src.replace(amd_branch, arm_branch, 1)
    return src


# 2. Populate initial CPU frequency on ARM64 (where /proc/cpuinfo lacks 'cpu MHz')
def patch_linux_cpu(src: str) -> str:
    old_init = """    CpuObject::initialize();
    m_frequency->setValue(m_initialFrequency);"""
    new_init = """    CpuObject::initialize();
    if (m_initialFrequency <= 0.0) {
        bool curOk = false;
        double cur = readCpuFreq(id(), QStringLiteral("scaling_cur_freq"), curOk);
        if (curOk) {
            m_initialFrequency = cur;
        }
    }
    m_frequency->setValue(m_initialFrequency);"""
    if "scaling_cur_freq" in src and "curOk" not in src and old_init in src:
        src = src.replace(old_init, new_init, 1)
    return src


# 3. Allow microSD/eMMC (SdMmc) and USB drives in DisksPlugin (only skip optical CD-ROM drives)
def patch_disks(src: str) -> str:
    old_check = "if (type == Solid::StorageDrive::HardDisk) {"
    new_check = "if (type != Solid::StorageDrive::CdromDrive) {"
    if old_check in src:
        src = src.replace(old_check, new_check, 1)
    return src


# 4. Add Broadcom VideoCore VII (V3D) GPU support on Raspberry Pi 5
v3d_header = """/*
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 */

#pragma once

#include <QHash>
#include <QByteArray>
#include "GpuDevice.h"

struct udev_device;

class LinuxV3dGpu : public GpuDevice
{
    Q_OBJECT

public:
    LinuxV3dGpu(const QString &id, const QString &name, udev_device *device);
    ~LinuxV3dGpu() override;

    void initialize() override;
    void update() override;

private:
    void sampleGpuStats(bool updateSensor);

    udev_device *m_device = nullptr;
    QString m_statsPath;
    QHash<QByteArray, quint64> m_prevRuntime;
    QHash<QByteArray, quint64> m_prevTimestamp;
};
"""

v3d_source = """/*
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 */

#include "LinuxV3dGpu.h"

#include <algorithm>
#include <libudev.h>
#include <QFile>

LinuxV3dGpu::LinuxV3dGpu(const QString &id, const QString &name, udev_device *device)
    : GpuDevice(id, name)
    , m_device(device)
{
    udev_device_ref(m_device);
    m_statsPath = QString::fromLocal8Bit(udev_device_get_syspath(m_device)) + QStringLiteral("/gpu_stats");
}

LinuxV3dGpu::~LinuxV3dGpu()
{
    udev_device_unref(m_device);
}

void LinuxV3dGpu::initialize()
{
    GpuDevice::initialize();
    m_nameProperty->setValue(QStringLiteral("Broadcom VideoCore VII (V3D)"));
    sampleGpuStats(false);
    update();
}

void LinuxV3dGpu::sampleGpuStats(bool updateSensor)
{
    QFile f(m_statsPath);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return;
    }

    double maxBusy = 0.0;
    bool haveDelta = false;
    // Skip header line: queue timestamp jobs runtime
    QByteArray line = f.readLine();
    for (line = f.readLine(); !line.isEmpty(); line = f.readLine()) {
        const QList<QByteArray> parts = line.simplified().split(' ');
        if (parts.size() < 4) {
            continue;
        }
        const QByteArray &queue = parts[0];
        if (queue == "cpu") {
            continue;
        }
        bool tsOk = false;
        bool rtOk = false;
        const quint64 ts = parts[1].toULongLong(&tsOk);
        const quint64 rt = parts[3].toULongLong(&rtOk);
        if (!tsOk || !rtOk) {
            continue;
        }
        if (updateSensor && m_prevTimestamp.contains(queue)) {
            const quint64 prevTs = m_prevTimestamp.value(queue);
            const quint64 prevRt = m_prevRuntime.value(queue);
            if (ts > prevTs && rt >= prevRt) {
                const double busy = ( static_cast<double>(rt - prevRt) / static_cast<double>(ts - prevTs) ) * 100.0;
                maxBusy = std::max(maxBusy, busy);
                haveDelta = true;
            }
        }
        m_prevTimestamp.insert(queue, ts);
        m_prevRuntime.insert(queue, rt);
    }

    if (updateSensor && haveDelta) {
        m_usageProperty->setValue(std::clamp(maxBusy, 0.0, 100.0));
    }
}

void LinuxV3dGpu::update()
{
    sampleGpuStats(true);

    QFile tempFile(QStringLiteral("/sys/class/thermal/thermal_zone0/temp"));
    if (tempFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
        bool ok = false;
        const int milliC = tempFile.readAll().trimmed().toInt(&ok);
        if (ok) {
            m_temperatureProperty->setValue(milliC / 1000.0);
        }
    }
}

#include "moc_LinuxV3dGpu.cpp"
"""


def patch_gpu_backend(src: str) -> str:
    if "LinuxV3dGpu.h" not in src:
        src = src.replace('#include "LinuxNvidiaGpu.h"', '#include "LinuxNvidiaGpu.h"\n#include "LinuxV3dGpu.h"', 1)
    old_block = """        } else if (vendor == nvidiaVendor) {
            gpu = new LinuxNvidiaGpu{gpuId, gpuName, pciDevice};
        } else {"""
    new_block = """        } else if (vendor == nvidiaVendor) {
            gpu = new LinuxNvidiaGpu{gpuId, gpuName, pciDevice};
        } else if (pciDevice && qstrcmp(udev_device_get_driver(pciDevice), "v3d") == 0) {
            gpu = new LinuxV3dGpu{gpuId, gpuName, pciDevice};
        } else {"""
    if "LinuxV3dGpu{" not in src:
        if old_block not in src:
            raise RuntimeError("Could not find GPU vendor block in LinuxBackend.cpp")
        src = src.replace(old_block, new_block, 1)
    return src


def patch_gpu_cmake(src: str) -> str:
    old_srcs = "target_sources(ksystemstats_plugin_gpu PRIVATE LinuxAmdGpu.cpp LinuxNvidiaGpu.cpp LinuxBackend.cpp NvidiaGpu.cpp NvidiaSmiProcess.cpp)"
    new_srcs = "target_sources(ksystemstats_plugin_gpu PRIVATE LinuxAmdGpu.cpp LinuxNvidiaGpu.cpp LinuxV3dGpu.cpp LinuxBackend.cpp NvidiaGpu.cpp NvidiaSmiProcess.cpp)"
    if "LinuxV3dGpu.cpp" not in src:
        if old_srcs not in src:
            raise RuntimeError("Could not find target_sources in plugins/gpu/CMakeLists.txt")
        src = src.replace(old_srcs, new_srcs, 1)
    return src


patch_file("plugins/cpu/linuxcpuplugin.cpp", patch_linux_cpu_plugin)
patch_file("plugins/cpu/linuxcpu.cpp", patch_linux_cpu)
patch_file("plugins/disks/disks.cpp", patch_disks)

gpu_dir = os.path.join(root, "plugins/gpu")
with open(os.path.join(gpu_dir, "LinuxV3dGpu.h"), "w", encoding="utf-8") as f:
    f.write(v3d_header)
with open(os.path.join(gpu_dir, "LinuxV3dGpu.cpp"), "w", encoding="utf-8") as f:
    f.write(v3d_source)
print("[patch-ksystemstats-pi5] Wrote plugins/gpu/LinuxV3dGpu.h & LinuxV3dGpu.cpp")

patch_file("plugins/gpu/LinuxBackend.cpp", patch_gpu_backend)
patch_file("plugins/gpu/CMakeLists.txt", patch_gpu_cmake)
