# 🍓 KRubus — Raspberry Pi OS (Trixie) KDE Plasma 6 Edition für Raspberry Pi 5

**KRubus** (*K*DE + *Rubus idaeus*) ist eine speziell für den **Raspberry Pi 5 & Compute Module 5 (BCM2712 / Cortex-A76)** angepasste Distribution auf Basis von **Raspberry Pi OS (Debian 13 Trixie)** mit **KDE Plasma 6 (Wayland)** und einem eigenen, auf die Cortex-A76-Mikroarchitektur optimierten **APT-Repository**.

---

## ⚡ Cortex-A76 Optimiertes APT-Repository (`+pi5`)

Alle Pakete in [`packages.txt`](./packages.txt) werden automatisiert über GitHub Actions nativ auf ARM64 gebaut und über GitHub Pages (`gh-pages`) ausgeliefert:

- **Target & Mikroarchitektur (`ARCH_FLAGS`):**
  `-mcpu=cortex-a76+crypto -mtune=cortex-a76 -mno-fix-cortex-a53-835769 -mno-fix-cortex-a53-843419 -mbranch-protection=none -mno-outline-atomics -mearly-ra=all`
- **Code-Gen, Loop-Nest & Polyhedral-Optimizer (`OPT_FLAGS` – durchgehend für alle Stufen inkl. Qt6 & KDE Plasma 6):**
  `-O3 -ftree-vectorize -fvect-cost-model=dynamic -fomit-frame-pointer -fno-semantic-interposition -fno-plt -fipa-pta -floop-interchange -floop-unroll-and-jam -fpeel-loops -funroll-loops -ftracer -fgraphite-identity -floop-nest-optimize -g0`
- **Link-Time Optimization & Linker (`LTO_FLAGS` & `LINK_FLAGS`):**
  `-flto=auto -ffat-lto-objects -fuse-linker-plugin -fdevirtualize-at-ltrans -Wl,-O3 -Wl,--as-needed -Wl,-Bsymbolic-functions`
- **Python 3.13 PGO:** Voller Profile-Guided-Optimization-Trainingslauf aktiviert.

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
