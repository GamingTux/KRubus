# 🍓 KRubus — Raspberry Pi OS (Trixie) KDE Plasma 6 Edition für Raspberry Pi 5

**KRubus** (*K*DE + *Rubus idaeus*) ist eine speziell für den **Raspberry Pi 5 & Compute Module 5 (BCM2712 / Cortex-A76)** angepasste Distribution auf Basis von **Raspberry Pi OS (Debian 13 Trixie)** mit **KDE Plasma 6 (Wayland)** und einem eigenen, auf die Cortex-A76-Mikroarchitektur optimierten **APT-Repository**.

---

## ⚡ Cortex-A76 Optimiertes APT-Repository (`+pi5`)

Alle Pakete in [`packages.txt`](./packages.txt) werden automatisiert über GitHub Actions nativ auf ARM64 gebaut und über GitHub Pages (`gh-pages`) ausgeliefert:

- **Target, Cache-Geometrie & Mikroarchitektur (`ARCH_FLAGS`):**
  `-mcpu=cortex-a76+crypto -mtune=cortex-a76 -mno-fix-cortex-a53-835769 -mno-fix-cortex-a53-843419 -mbranch-protection=none -mno-outline-atomics -mearly-ra=all --param l1-cache-size=64 --param l1-cache-line-size=64 --param l2-cache-size=512`
- **Code-Gen, IEEE-Safe FP-SIMD, Loop-Nest & Polyhedral-Optimizer (`OPT_FLAGS` – durchgehend für alle 392 Quellpakete inkl. Qt6 & KDE Plasma 6):**
  `-O3 -ftree-vectorize -fvect-cost-model=dynamic -fomit-frame-pointer -fno-semantic-interposition -fno-math-errno -fno-trapping-math -ffp-contract=fast -fprefetch-loop-arrays -floop-interchange -floop-unroll-and-jam -fpeel-loops -funroll-loops -ftracer -fgraphite-identity -floop-nest-optimize -g0`
- **Link-Time Optimization & 16K-Page-Linker (`LTO_FLAGS` & `LINK_FLAGS`):**
  `-flto=auto -ffat-lto-objects -fuse-linker-plugin -fdevirtualize-at-ltrans -Wl,-O3 -Wl,--as-needed -Wl,--hash-style=gnu -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384`
- **Hardware-Spezifische Paket-Optimierungen:**
  - **`linux` (`rpi-2712` Custom Kernel):** 16K Pages, `1000 Hz` Timer (`CONFIG_HZ_1000=y`), alle 29 fremden CPU-Errata & PAC/BTI entfernt, kompiliert mit `-mcpu=cortex-a76+crypto -O3`.
  - **`mesa` (V3D/VC4-Only):** Alle fremden GPU-Treiber (AMD, Nvidia, Intel, Qualcomm, Mali) entfernt – ~60 % schlankere `libgallium` & Vulkan-Treiber.
  - **`glibc` (`libc6`):** Direkt mit Cortex-A76 LSE-Atomics, RCPC, NEON/FP16 und 64KB/512KB Cache-Parametern gebaut.
  - **`python3.13`:** Voller Profile-Guided-Optimization (PGO) Trainingslauf aktiviert.
  - **Paket-Kompression:** Alle `.deb`-Pakete werden automatisch mit `dpkg-deb -Zxz -z9 -Sextreme` (`xz -9e`) maximal komprimiert.

### 🌐 Web-Katalog & APT-Einbindung

- **Paket-Katalog:** [https://gamingtux.github.io/KRubus/](https://gamingtux.github.io/KRubus/)

```bash
# 1. GPG-Keyring installieren
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://gamingtux.github.io/KRubus/krubus.gpg -o /etc/apt/keyrings/krubus.gpg

# 2. KRubus APT-Quelle hinzufügen
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/krubus.gpg] https://gamingtux.github.io/KRubus trixie main" | sudo tee /etc/apt/sources.list.d/krubus.list

# 3. APT-Priorität setzen (bevorzugt +pi5 Pakete)
cat << 'EOF' | sudo tee /etc/apt/preferences.d/krubus-pi5.pref
Package: *
Pin: origin "gamingtux.github.io"
Pin-Priority: 1001
EOF

sudo apt update && sudo apt full-upgrade
sudo apt install -y krubus-kernel-hook
```

---

## 📁 Projektstruktur

- [`packages.txt`](./packages.txt) — Paketliste für den Cortex-A76 Repo-Builder (Stufe 0 System/Multimedia + Stufe 1 Qt6/KF6/Plasma 6/KDE Gear)
- [`build-repo.sh`](./build-repo.sh) — Inkrementeller Delta-Repo-Builder mit 4h45m Zeitbudget, Auto-Continuation, Orphan-Cleaner und GPG-Signierung
- [`generate-repo-index.py`](./generate-repo-index.py) — Generator für den interaktiven Web-Katalog (`index.html`) auf GitHub Pages
- [`packages/`](./packages/) — Verzeichnis für eigene lokale KRubus-Pakete
- [`.github/workflows/build.yml`](./.github/workflows/build.yml) — CI/CD-Workflow für den automatischen Bau und das Deployment des APT-Repositorys
