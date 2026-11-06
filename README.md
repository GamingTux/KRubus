# 🍓 KRubus — Raspberry Pi OS (Trixie) KDE Plasma 6 Edition für Raspberry Pi 5

**KRubus** (*K*DE + *Rubus idaeus*) ist eine speziell für den **Raspberry Pi 5 & Compute Module 5 (BCM2712 / Cortex-A76)** angepasste Distribution auf Basis von **Raspberry Pi OS (Debian 13 Trixie)** mit **KDE Plasma 6 (Wayland)** und einem eigenen, auf die Cortex-A76-Mikroarchitektur optimierten **APT-Repository**.

---

## ⚡ Cortex-A76 Optimiertes APT-Repository (`+pi5`)

Alle Pakete in [`packages.txt`](./packages.txt) werden automatisiert über GitHub Actions nativ auf ARM64 gebaut und über GitHub Pages (`gh-pages`) ausgeliefert:

- **Compiler-Flags (Stufe 0 – System, Crypto, Wayland/Mesa, Codecs, PipeWire, FFmpeg):**
  `-march=armv8.2-a+crypto+fp16+dotprod -mtune=cortex-a76 -ftree-vectorize -O3` (+ Fat-LTO wo unterstützt)
- **Compiler-Flags (Stufe 1 – Qt6, KDE Frameworks 6, KDE Plasma 6 & KDE Gear):**
  `-march=armv8.2-a+crypto+fp16+dotprod -mtune=cortex-a76 -ftree-vectorize -O2`

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
```

---

## 📁 Projektstruktur

- [`packages.txt`](./packages.txt) — Paketliste für den Cortex-A76 Repo-Builder (Stufe 0 System/Multimedia + Stufe 1 Qt6/KF6/Plasma 6/KDE Gear)
- [`build-repo.sh`](./build-repo.sh) — Inkrementeller Delta-Repo-Builder mit 4h45m Zeitbudget, Auto-Continuation, Orphan-Cleaner und GPG-Signierung
- [`generate-repo-index.py`](./generate-repo-index.py) — Generator für den interaktiven Web-Katalog (`index.html`) auf GitHub Pages
- [`packages/`](./packages/) — Verzeichnis für eigene lokale KRubus-Pakete
- [`.github/workflows/build.yml`](./.github/workflows/build.yml) — CI/CD-Workflow für den automatischen Bau und das Deployment des APT-Repositorys
