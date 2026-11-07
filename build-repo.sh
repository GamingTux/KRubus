#!/usr/bin/env bash
set -eu

export DEBIAN_FRONTEND=noninteractive
export FORCE_UNSAFE_CONFIGURE=1
export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
export DEB_BUILD_PROFILES="nocheck"
# Verhindert dpkg-gensymbols Abbrüche bei C++/Qt6/KF6 Template-Inlining durch Cortex-A76 Optimierungen
export DPKG_GENSYMBOLS_CHECK_LEVEL=0

# Basis-Architektur- & High-End-Optimierungs-Flags für den BCM2712 (Cortex-A76, Pi 5 & CM5)
# 1. Entfernt Debians generische Standard-Flags (-g, -O2 und das auf Armv8.2 nutzlose PAC/BTI -mbranch-protection=standard)
STRIP_FLAGS="-g -O2 -mbranch-protection=standard"
# 2. Exaktes Cortex-A76 Target inkl. Crypto/FP16/DotProd/RCPC, ohne alte Pi-3/A53-Errata-NOPs, mit Arm Early-RA & BCM2712 L1/L2 Cache-Geometrie (64KB L1d, 64B Line, 512KB L2)
ARCH_FLAGS="-mcpu=cortex-a76+crypto -mtune=cortex-a76 -mno-fix-cortex-a53-835769 -mno-fix-cortex-a53-843419 -mbranch-protection=none -mno-outline-atomics -mearly-ra=all --param l1-cache-size=64 --param l1-cache-line-size=64 --param l2-cache-size=512"
# 3. Maximale Code-Gen-, Inlining-, IEEE-sichere FP-SIMD- (-fno-math-errno -fno-trapping-math -ffp-contract=fast), Prefetch-, Loop-Nest- & Polyhedral-Optimierung (Graphite)
OPT_FLAGS="-O3 -ftree-vectorize -fvect-cost-model=dynamic -fomit-frame-pointer -fno-semantic-interposition -fno-math-errno -fno-trapping-math -ffp-contract=fast -fprefetch-loop-arrays -floop-interchange -floop-unroll-and-jam -fpeel-loops -funroll-loops -ftracer -fgraphite-identity -floop-nest-optimize -Wno-error=array-bounds -Wno-error=stringop-overflow -Wno-error=maybe-uninitialized -g0"
SAFE_OPT_FLAGS="-O2 -ftree-vectorize -fvect-cost-model=dynamic -fomit-frame-pointer -fno-math-errno -fno-trapping-math -ffp-contract=fast -Wno-error=array-bounds -Wno-error=stringop-overflow -Wno-error=maybe-uninitialized -g0"
# 4. Vollständige Link-Time Optimization & 16K-Hardware-Page-Alignment für den rpi-2712 Kernel
LTO_FLAGS="-flto=auto -ffat-lto-objects -fuse-linker-plugin -fdevirtualize-at-ltrans"
LINK_FLAGS="-Wl,-O3 -Wl,--as-needed -Wl,--hash-style=gnu -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

SCRIPT_START_TIME="$(date +%s)"
# 4h 45m (17100s) Zeitbudget pro GitHub-Actions-Lauf (Sicherheitsabstand zum 6h-Hard-Limit)
MAX_RUN_SECONDS=17100
TIME_LIMIT_REACHED=0

ROOT_DIR="$(pwd)"
REPO_DIR="$ROOT_DIR/repo"
SUITE="trixie"
PACKAGES_FILE="$REPO_DIR/dists/${SUITE}/main/binary-arm64/Packages"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/tmp/github_step_summary.md}"

mkdir -p "$REPO_DIR/pool/main" "$REPO_DIR/dists/${SUITE}/main/binary-arm64"
rm -f "$ROOT_DIR/.build_failed"

# Erzwinge maximale .deb-Kompression (-Zxz -z9 -Sextreme) global für alle dpkg-deb Build-Aufrufe
if [[ ! -f /usr/bin/dpkg-deb.distrib ]]; then
  dpkg-divert --local --rename --add /usr/bin/dpkg-deb >/dev/null
  cat << 'EOF' > /usr/bin/dpkg-deb
#!/usr/bin/env bash
is_build=0
for arg in "$@"; do
  if [[ "$arg" == "-b" || "$arg" == "--build" ]]; then
    is_build=1
    break
  fi
done
if [[ "$is_build" -eq 1 ]]; then
  args=()
  skip=0
  for arg in "$@"; do
    if [[ "$skip" -eq 1 ]]; then
      skip=0
      continue
    fi
    case "$arg" in
      -Z|-z|-S) skip=1 ;;
      -Z*|-z*|-S*|--compression=*|--compression-level=*|--compression-strategy=*) ;;
      *) args+=("$arg") ;;
    esac
  done
  exec /usr/bin/dpkg-deb.distrib -Zxz -z9 -Sextreme "${args[@]}"
else
  exec /usr/bin/dpkg-deb.distrib "$@"
fi
EOF
  chmod +x /usr/bin/dpkg-deb
fi

# Globaler Debhelper dh_missing Wrapper: Verhindert Build-Abbrüche (--fail-missing), wenn optionale Tools im Container (valac/groff) Zusatzdateien erzeugen oder Stage 3 (-B) Arch:all überspringt
if [[ ! -f /usr/bin/dh_missing.distrib ]]; then
  dpkg-divert --local --rename --add /usr/bin/dh_missing
  cat << 'EOF' > /usr/bin/dh_missing
#!/bin/bash
args=()
for arg in "$@"; do
  [[ "$arg" == "--fail-missing" ]] && continue
  args+=("$arg")
done
exec /usr/bin/dh_missing.distrib --list-missing "${args[@]}"
EOF
  chmod +x /usr/bin/dh_missing
fi

# Unnötige Dokumentations-, Debug-, Source- und Cross-Compile-Pakete aus bestehendem Pool bereinigen
rm -f "$REPO_DIR"/pool/main/*dbgsym*.deb \
      "$REPO_DIR"/pool/main/*-dbg_*.deb \
      "$REPO_DIR"/pool/main/*.ddeb \
      "$REPO_DIR"/pool/main/*-doc_*.deb \
      "$REPO_DIR"/pool/main/*-docs_*.deb \
      "$REPO_DIR"/pool/main/*-examples_*.deb \
      "$REPO_DIR"/pool/main/*-tests_*.deb \
      "$REPO_DIR"/pool/main/*-source_*.deb \
      "$REPO_DIR"/pool/main/*-mingw-*.deb

# Falls zlib1g-dev oder liblz4-dev aus einem früheren Lauf ohne -ffat-lto-objects leere .a-Archive enthalten, zum Neubau entfernen
for check_dev in "$REPO_DIR"/pool/main/zlib1g-dev_*.deb "$REPO_DIR"/pool/main/liblz4-dev_*.deb; do
  [[ -f "$check_dev" ]] || continue
  tmp_chk="$(mktemp -d)"
  dpkg-deb -x "$check_dev" "$tmp_chk"
  a_file="$(find "$tmp_chk" -name "*.a" | head -n 1)"
  if [[ -n "$a_file" ]] && [[ "$(nm "$a_file" 2>/dev/null | grep -c ' T ' || true)" -eq 0 ]]; then
    echo "🧹 Entferne altes Slim-LTO-Paket $(basename "$check_dev") für sauberen Neubau mit -ffat-lto-objects..."
    rm -f "$REPO_DIR"/pool/main/zlib1g*.deb "$REPO_DIR"/pool/main/libminizip*.deb \
          "$REPO_DIR"/pool/main/liblz4*.deb "$REPO_DIR"/pool/main/lz4_*.deb
  fi
  rm -rf "$tmp_chk"
done

# Lokales APT-Repository aktualisieren, damit apt-get build-dep alle bereits gebauten +pi5 Pakete sauber auflöst
update_local_apt_repo() {
  (
    cd "$REPO_DIR"
    if compgen -G "pool/main/*.deb" > /dev/null; then
      dpkg-scanpackages --arch arm64 pool/ > "dists/${SUITE}/main/binary-arm64/Packages" 2>/dev/null || true
      gzip -9c "dists/${SUITE}/main/binary-arm64/Packages" > "dists/${SUITE}/main/binary-arm64/Packages.gz" 2>/dev/null || true
    fi
  )
  echo "deb [trusted=yes] file:${REPO_DIR} ${SUITE} main" > /etc/apt/sources.list.d/krubus-local.list
  apt-get update -o Dir::Etc::sourcelist="sources.list.d/krubus-local.list" \
                 -o Dir::Etc::sourceparts="-" \
                 -o APT::Get::List-Cleanup="0" >/dev/null 2>&1 || apt-get update >/dev/null 2>&1 || true
}

# Zu Beginn sofort den Index aus allen vorhandenen .deb-Dateien in pool/main synchronisieren
update_local_apt_repo

BUILD_QUEUE="/tmp/build_queue.txt"
cp -f "$ROOT_DIR/packages.txt" "$BUILD_QUEUE"

TOTAL="$(grep -vE '^\s*(#|$)' "$BUILD_QUEUE" | wc -l | xargs)"
CURRENT=0
BUILD_FAILED=0
ALLOWED_SOURCES=()
FINALIZED=0

# Lokale KRubus-Pakete aus packages/ automatisch bauen, in pool/main bereitstellen und schützen
if [[ -d "$ROOT_DIR/packages" ]]; then
  for pkg_dir in "$ROOT_DIR"/packages/*; do
    [[ -d "$pkg_dir/DEBIAN" ]] || continue
    pkg_name="$(grep -i '^Package:' "$pkg_dir/DEBIAN/control" | awk '{print $2}')"
    pkg_ver="$(grep -i '^Version:' "$pkg_dir/DEBIAN/control" | awk '{print $2}')"
    pkg_arch="$(grep -i '^Architecture:' "$pkg_dir/DEBIAN/control" | awk '{print $2}')"
    target_deb="$REPO_DIR/pool/main/${pkg_name}_${pkg_ver}_${pkg_arch}.deb"

    echo "📦 Baue lokales KRubus-Paket ${pkg_name} (${pkg_ver})..."
    rm -f "$REPO_DIR/pool/main/${pkg_name}_"*.deb
    dpkg-deb --root-owner-group -b "$pkg_dir" "$target_deb" >/dev/null
    ALLOWED_SOURCES+=("$pkg_name")
  done
  update_local_apt_repo
fi

finalize_and_sign_repo() {
  [[ "$FINALIZED" -eq 1 ]] && return 0
  FINALIZED=1
  set +e

  # Automatischer Orphan-Cleaner: Lösche verwaiste .deb-Pakete in pool/main, deren Quellpaket aus packages.txt entfernt wurde
  if [[ "$TIME_LIMIT_REACHED" -eq 0 && "$CURRENT" -ge "$TOTAL" && ${#ALLOWED_SOURCES[@]} -gt 0 ]]; then
    declare -A ALLOWED_MAP=()
    for s in "${ALLOWED_SOURCES[@]}"; do
      ALLOWED_MAP["$s"]=1
    done
    for deb in "$REPO_DIR"/pool/main/*.deb; do
      [[ -e "$deb" ]] || continue
      deb_src="$(dpkg-deb -f "$deb" Source 2>/dev/null | awk '{print $1}' || true)"
      deb_pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
      [[ -z "$deb_src" ]] && deb_src="$deb_pkg"
      if [[ -z "${ALLOWED_MAP[$deb_src]:-}" && -z "${ALLOWED_MAP[$deb_pkg]:-}" ]]; then
        echo "🧹 Orphan-Cleaner: Entferne verwaistes Paket $(basename "$deb") (Quellpaket: $deb_src nicht mehr in packages.txt)"
        rm -f "$deb"
      fi
    done
  fi

  cd "$REPO_DIR"
  if compgen -G "pool/main/*.deb" > /dev/null; then
    update_local_apt_repo

    echo "[$(date -u '+%H:%M:%S')] 📦 Generiere APT-Repository-Index und GPG-Signaturen..."
    apt-ftparchive \
      -o APT::FTPArchive::Release::Origin="KRubus" \
      -o APT::FTPArchive::Release::Label="KRubus" \
      -o APT::FTPArchive::Release::Suite="${SUITE}" \
      -o APT::FTPArchive::Release::Codename="${SUITE}" \
      -o APT::FTPArchive::Release::Architectures="arm64" \
      -o APT::FTPArchive::Release::Components="main" \
      release "dists/${SUITE}" > "dists/${SUITE}/Release"

    if [[ -n "${GPG_PRIVATE_KEY:-}" ]]; then
      export GNUPGHOME="$(mktemp -d)"
      chmod 700 "$GNUPGHOME"
      echo "$GPG_PRIVATE_KEY" | gpg --batch --yes --import 2>/dev/null

      rm -f "dists/${SUITE}/InRelease" "dists/${SUITE}/Release.gpg" krubus.gpg
      gpg --batch --yes --digest-algo SHA512 --clearsign -o "dists/${SUITE}/InRelease" "dists/${SUITE}/Release"
      gpg --batch --yes --digest-algo SHA512 -abs -o "dists/${SUITE}/Release.gpg" "dists/${SUITE}/Release"
      gpg --batch --yes --export > krubus.gpg

      rm -rf "$GNUPGHOME"
    fi
    REPO_SIZE_MB="$(du -sm pool/main | awk '{print $1}')"
    echo "[$(date -u '+%H:%M:%S')] 🔐 APT-Repository erfolgreich signiert (Aktuelle Pool-Größe: ${REPO_SIZE_MB} MB / 1000 MB GitHub-Pages-Limit)."

    echo "[$(date -u '+%H:%M:%S')] 🌐 Generiere interaktiven Web-Katalog (index.html)..."
    python3 "$ROOT_DIR/generate-repo-index.py" "$REPO_DIR" || echo "⚠️ Konnte index.html nicht generieren"
  else
    echo "[$(date -u '+%H:%M:%S')] ⚠️ Keine .deb-Pakete in pool/main vorhanden – überspringe Signierung."
  fi

  cd "$ROOT_DIR"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "BUILD_FAILED=${BUILD_FAILED}" >> "$GITHUB_ENV"
    echo "TIME_LIMIT_REACHED=${TIME_LIMIT_REACHED}" >> "$GITHUB_ENV"
  fi

  if [[ "$BUILD_FAILED" -eq 1 ]]; then
    touch "$ROOT_DIR/.build_failed"
    echo "[$(date -u '+%H:%M:%S')] ⚠️ Lauf mit Fehlern beendet (BUILD_FAILED=1). Bisher gebaute Pakete werden als Partial-Deploy gesichert."
  elif [[ "$TIME_LIMIT_REACHED" -eq 1 ]]; then
    echo "[$(date -u '+%H:%M:%S')] ⏳ Zeitbudget erreicht – bisher gebaute Pakete werden veröffentlicht und Folge-Lauf wird gestartet."
  else
    echo "[$(date -u '+%H:%M:%S')] 🎉 Alle $TOTAL Pakete erfolgreich verarbeitet!"
  fi
}

trap finalize_and_sign_repo EXIT

{
  echo "## 🍓 KRubus ARM64 (Cortex-A76) Build-Dashboard"
  echo ""
  echo "| # | Paket | Version | Optimierung | Status | Dauer |"
  echo "|---|---|---|---|---|---|"
} >> "$SUMMARY_FILE"

run_dpkg_build_with_heartbeat() {
  local pkg_name="$1"
  local cur_idx="$2"
  local tot_idx="$3"
  local log_f="$4"
  local build_flag="${5:--b}"
  local rc=0

  # GITHUB_ACTIONS und CI im Build-Subprozess entfernen, damit Upstream-Buildskripte (wie re2 setup.py) kein Bazel-CI erzwingen
  env -u GITHUB_ACTIONS -u CI dpkg-buildpackage "$build_flag" -uc -us -j"$(nproc)" < /dev/null >> "$log_f" 2>&1 &
  local b_pid=$!

  (
    local elapsed=0
    while kill -0 "$b_pid" 2>/dev/null; do
      sleep 60
      if kill -0 "$b_pid" 2>/dev/null; then
        elapsed=$((elapsed + 60))
        echo "   ⏱️ [$cur_idx/$tot_idx] $pkg_name kompiliert noch... (${elapsed}s)"
      fi
    done
  ) &
  local hb_pid=$!

  if wait "$b_pid"; then
    rc=0
  else
    rc=$?
  fi

  kill "$hb_pid" 2>/dev/null || true
  wait "$hb_pid" 2>/dev/null || true
  return "$rc"
}

while IFS= read -r -u 3 line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  pkg="$(echo "$line" | xargs)"
  [[ -z "$pkg" ]] && continue

  CURRENT=$((CURRENT + 1))
  PKG_START_TIME="$(date +%s)"
  LOG_FILE="/tmp/build-${pkg}.log"
  : > "$LOG_FILE"

  # 1. Maximales Performance-Profil (-O3 + Graphite + Loop-Nest + LTO für alle Pakete; automatischer Fallback greift bei Inline-ASM-Konflikten)
  OPT_LEVEL="-O3+LTO"
  USE_LTO=1
  export DEB_CFLAGS_MAINT_STRIP="$STRIP_FLAGS"
  export DEB_CXXFLAGS_MAINT_STRIP="$STRIP_FLAGS"
  PKG_LINK_FLAGS="$LINK_FLAGS"

  case "$pkg" in
    libgcrypt20)
      USE_LTO=0
      OPT_LEVEL="-O2 (jitterentropy-safe)"
      # libgcrypt20 ersetzt in random/Makefile per sed das erste -O2 durch -O0 für jitterentropy; kein -O3 anhängen
      export DEB_CFLAGS_MAINT_STRIP="-g -mbranch-protection=standard"
      export DEB_CXXFLAGS_MAINT_STRIP="-g -mbranch-protection=standard"
      export DEB_CFLAGS_MAINT_APPEND="$ARCH_FLAGS -fomit-frame-pointer -g0"
      export DEB_CXXFLAGS_MAINT_APPEND="$ARCH_FLAGS -fomit-frame-pointer -g0"
      export DEB_LDFLAGS_MAINT_APPEND="$LINK_FLAGS"
      ;;
    fftw3|openblas|blis|lapack|eigen3)
      USE_LTO=0
      OPT_LEVEL="Upstream-SIMD"
      export DEB_CFLAGS_MAINT_APPEND="$ARCH_FLAGS -fomit-frame-pointer -g0"
      export DEB_CXXFLAGS_MAINT_APPEND="$ARCH_FLAGS -fomit-frame-pointer -g0"
      export DEB_LDFLAGS_MAINT_APPEND="$LINK_FLAGS"
      ;;
    jemalloc)
      USE_LTO=0
      OPT_LEVEL="-O3 (malloc-interpose)"
      # jemalloc benötigt Standard-Symbol-Interposition für malloc/free Ersatz
      export DEB_CFLAGS_MAINT_APPEND="$ARCH_FLAGS -O3 -ftree-vectorize -fomit-frame-pointer -funroll-loops -g0"
      export DEB_CXXFLAGS_MAINT_APPEND="$ARCH_FLAGS -O3 -ftree-vectorize -fomit-frame-pointer -funroll-loops -g0"
      export DEB_LDFLAGS_MAINT_APPEND="$LINK_FLAGS"
      ;;
    glibc|linux)
      USE_LTO=0
      PKG_LINK_FLAGS=""
      # glibc (HOST_CFLAGS) und linux (KCFLAGS) erhalten ihre Cortex-A76-Flags direkt über debian/rules(.real), damit Host-Tools (rtld/fixdep/objtool) sauber bauen
      export DEB_CFLAGS_MAINT_STRIP=""
      export DEB_CXXFLAGS_MAINT_STRIP=""
      export DEB_CFLAGS_MAINT_APPEND=""
      export DEB_CXXFLAGS_MAINT_APPEND=""
      export DEB_LDFLAGS_MAINT_APPEND=""
      ;;
    systemd)
      USE_LTO=0
      OPT_LEVEL="-O3 (EFI-4K-safe)"
      PKG_LINK_FLAGS="-Wl,-O3 -Wl,--as-needed -Wl,--hash-style=gnu"
      # systemd-boot UEFI-Stubs (elf2efi.py) verlangen exakt 4096-Byte PE-Alignment (kein max-page-size=16384) und saubere Freestanding/Interposition-Flags
      export DEB_CFLAGS_MAINT_APPEND="$ARCH_FLAGS -O3 -ftree-vectorize -fvect-cost-model=dynamic -fomit-frame-pointer -Wno-error -g0"
      export DEB_CXXFLAGS_MAINT_APPEND="$ARCH_FLAGS -O3 -ftree-vectorize -fvect-cost-model=dynamic -fomit-frame-pointer -Wno-error -g0"
      export DEB_LDFLAGS_MAINT_APPEND="$PKG_LINK_FLAGS"
      ;;
    xz-utils|tar|re2|gmp|libxcrypt|nettle|gnutls28|openssl|gnupg2|openssh|highway|icu|glib2.0|util-linux|coreutils|bash|dpkg|apt|e2fsprogs|udisks2|libblockdev|xorg-server|mesa|xwayland|librsvg|poppler|djvulibre|aom|svt-av1|jpeg-xl|libplacebo|alsa-lib|pulseaudio|pipewire|wireplumber|gstreamer1.0|gst-plugins-base1.0|gst-plugins-good1.0|gst-plugins-bad1.0|gst-plugins-ugly1.0|gst-libav1.0|ffmpeg|mpv|vlc|gtk+3.0|gtk4|python3.13|btop|libcamera|rpicam-apps|vulkan-loader|glslang|spirv-tools|shaderc|qt6-*|kf6-*|kwin|plasma-*|libplasma|breeze*|dolphin|konsole|kate|gwenview|okular|ark|kde-*|haruna|elisa-player|kolourpaint|partitionmanager)
      # Aus LMPE bekannte Pakete mit Inline-ASM, Rust oder Linker-Version-Scripts direkt ohne LTO-Umweg mit vollem -O3+Graphite bauen
      USE_LTO=0
      OPT_LEVEL="-O3"
      export DEB_CFLAGS_MAINT_APPEND="$ARCH_FLAGS $OPT_FLAGS"
      export DEB_CXXFLAGS_MAINT_APPEND="$ARCH_FLAGS $OPT_FLAGS"
      export DEB_LDFLAGS_MAINT_APPEND="$LINK_FLAGS"
      ;;
    *)
      export DEB_CFLAGS_MAINT_APPEND="$ARCH_FLAGS $OPT_FLAGS $LTO_FLAGS"
      export DEB_CXXFLAGS_MAINT_APPEND="$ARCH_FLAGS $OPT_FLAGS $LTO_FLAGS"
      export DEB_LDFLAGS_MAINT_APPEND="$LTO_FLAGS $LINK_FLAGS"
      ;;
  esac

  if [[ "$pkg" == "python3.13" ]]; then
    # PGO (Profile-Guided Optimization) für Python 3.13 aktiv lassen für +15-25% Interpreter-Speedup!
    export DEB_BUILD_OPTIONS="nocheck nobench parallel=$(nproc)"
    export DEB_BUILD_PROFILES="nocheck"
  elif [[ "$pkg" == "glibc" ]]; then
    USE_LTO=0
    OPT_LEVEL="-O3 (Cortex-A76 glibc)"
    export DEB_BUILD_OPTIONS="nocheck nodoc parallel=$(nproc)"
    export DEB_BUILD_PROFILES="nocheck nodoc noudeb nobiarch"
  elif [[ "$pkg" == "linux" ]]; then
    USE_LTO=0
    OPT_LEVEL="-O3 (1000Hz rpi-2712 + rpi-v8)"
    export DEB_BUILD_OPTIONS="nocheck nodoc terse parallel=$(nproc)"
    export DEB_BUILD_PROFILES="nocheck nodoc pkg.linux.nokerneldbg pkg.linux.nokerneldbginfo pkg.linux.nosource pkg.linux.notools pkg.linux.norust"
  else
    export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
    export DEB_BUILD_PROFILES="nocheck"
  fi

  # 2. Upstream-Quellversion und Quellpaket-Name ermitteln (höchste verfügbare Version wählen, Backports nur bei +rpt)
  QUERY_PKG="$pkg"
  UPSTREAM_VER=""
  for v in $(apt-cache showsrc "$QUERY_PKG" 2>/dev/null | awk '/^Version:/ {print $2}'); do
    if [[ "$v" == *"~bpo"* && "$v" != *"rpt"* ]]; then
      continue
    fi
    if [[ -z "$UPSTREAM_VER" ]] || dpkg --compare-versions "$v" gt "$UPSTREAM_VER"; then
      UPSTREAM_VER="$v"
    fi
  done

  SRC_NAME="$(apt-cache showsrc "$QUERY_PKG" 2>/dev/null | awk '/^Package:/ {print $2; exit}')"
  [[ -z "$SRC_NAME" ]] && SRC_NAME="$QUERY_PKG"
  ALLOWED_SOURCES+=("$pkg" "$QUERY_PKG" "$SRC_NAME")

  if [[ -z "$UPSTREAM_VER" ]]; then
    DURATION=$(( $(date +%s) - PKG_START_TIME ))
    echo "[$(date -u '+%H:%M:%S')] ❌ [$CURRENT/$TOTAL] Konnte Upstream-Version für $pkg ($QUERY_PKG) nicht ermitteln!"
    echo "| $CURRENT/$TOTAL | \`$pkg\` | \`n/a\` | \`$OPT_LEVEL\` | ❌ Fehler | ${DURATION}s |" >> "$SUMMARY_FILE"
    BUILD_FAILED=1
    continue
  fi

  PKG_VER_SUFFIX="+pi5"
  [[ "$pkg" == "ksystemstats" ]] && PKG_VER_SUFFIX="+pi5r1"
  TARGET_VER="${UPSTREAM_VER}${PKG_VER_SUFFIX}"

  # 3. Prüfen, ob im bestehenden Packages-Index bereits <upstream_version>+pi5 existiert
  DELTA_HIT=0
  EXISTING_DEBS=()
  if [[ -s "$PACKAGES_FILE" ]]; then
    if awk -v pkg="$pkg" -v qpkg="$QUERY_PKG" -v src="$SRC_NAME" -v ver="$TARGET_VER" '
      BEGIN { RS=""; FS="\n"; found=0 }
      {
        p=""; s=""; v=""
        for (i=1; i<=NF; i++) {
          if ($i ~ /^Package: /) { p = substr($i, 10) }
          else if ($i ~ /^Source: /) { s = substr($i, 9); sub(/ .*/, "", s) }
          else if ($i ~ /^Version: /) { v = substr($i, 10) }
        }
        if (s == "") s = p
        if ((s == pkg || s == qpkg || s == src || p == pkg || p == qpkg) && (v == ver || v == ver "1")) {
          found = 1
          exit 0
        }
      }
      END { exit (found ? 0 : 1) }
    ' "$PACKAGES_FILE"; then
      while IFS= read -r rel_deb; do
        [[ -n "$rel_deb" && -f "$REPO_DIR/$rel_deb" ]] && EXISTING_DEBS+=("$REPO_DIR/$rel_deb")
      done < <(awk -v pkg="$pkg" -v qpkg="$QUERY_PKG" -v src="$SRC_NAME" '
        BEGIN { RS=""; FS="\n" }
        {
          p=""; s=""; fn=""
          for (i=1; i<=NF; i++) {
            if ($i ~ /^Package: /) { p = substr($i, 10) }
            else if ($i ~ /^Source: /) { s = substr($i, 9); sub(/ .*/, "", s) }
            else if ($i ~ /^Filename: /) { fn = substr($i, 11) }
          }
          if (s == "") s = p
          if ((s == pkg || s == qpkg || s == src || p == pkg || p == qpkg) && fn != "") {
            print fn
          }
        }
      ' "$PACKAGES_FILE")

      if [[ ${#EXISTING_DEBS[@]} -gt 0 ]]; then
        DELTA_HIT=1
      fi
    fi
  fi

  # 4. Delta-Build-Treffer: Kompilieren überspringen
  if [[ "$DELTA_HIT" -eq 1 ]]; then
    DURATION=$(( $(date +%s) - PKG_START_TIME ))
    echo "[$(date -u '+%H:%M:%S')] ⏭️ [$CURRENT/$TOTAL] $pkg übersprungen (bereits aktuell im Repo)"
    echo "| $CURRENT/$TOTAL | \`$pkg\` | \`$TARGET_VER\` | \`$OPT_LEVEL\` | ⏭️ Delta-Skip | ${DURATION}s |" >> "$SUMMARY_FILE"
    continue
  fi

  # 4b. Zeitbudget prüfen, bevor ein neuer Paketbau gestartet wird
  TOTAL_ELAPSED=$(( $(date +%s) - SCRIPT_START_TIME ))
  if [[ "$TOTAL_ELAPSED" -ge "$MAX_RUN_SECONDS" ]]; then
    echo "[$(date -u '+%H:%M:%S')] ⏳ Zeitbudget (${TOTAL_ELAPSED}s / ${MAX_RUN_SECONDS}s) erreicht – sichere bisher gebaute Pakete und setze im Folge-Lauf fort."
    TIME_LIMIT_REACHED=1
    break
  fi

  echo "[$(date -u '+%H:%M:%S')] 🚀 [$CURRENT/$TOTAL] Starte $pkg ($UPSTREAM_VER) [Flags: $OPT_LEVEL]..."

  # Alte .deb-Dateien dieses Quellpakets aus ./repo/pool/main/ löschen
  if [[ -s "$PACKAGES_FILE" ]]; then
    while IFS= read -r old_rel; do
      [[ -n "$old_rel" ]] && rm -f "$REPO_DIR/$old_rel"
    done < <(awk -v pkg="$pkg" -v qpkg="$QUERY_PKG" -v src="$SRC_NAME" '
      BEGIN { RS=""; FS="\n" }
      {
        p=""; s=""; fn=""
        for (i=1; i<=NF; i++) {
          if ($i ~ /^Package: /) { p = substr($i, 10) }
          else if ($i ~ /^Source: /) { s = substr($i, 9); sub(/ .*/, "", s) }
          else if ($i ~ /^Filename: /) { fn = substr($i, 11) }
        }
        if (s == "") s = p
        if ((s == pkg || s == qpkg || s == src || p == pkg || p == qpkg) && fn != "") {
          print fn
        }
      }
    ' "$PACKAGES_FILE")
  fi

  for deb in "$REPO_DIR"/pool/main/*.deb; do
    [[ -e "$deb" ]] || continue
    deb_src="$(dpkg-deb -f "$deb" Source 2>/dev/null | awk '{print $1}' || true)"
    deb_pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
    [[ -z "$deb_src" ]] && deb_src="$deb_pkg"
    if [[ "$deb_src" == "$pkg" || "$deb_src" == "$QUERY_PKG" || "$deb_src" == "$SRC_NAME" || "$deb_pkg" == "$pkg" || "$deb_pkg" == "$QUERY_PKG" ]]; then
      rm -f "$deb"
    fi
  done

  # Quellcode laden, patchen und Build-Abhängigkeiten installieren
  STEP_OK=1
  rm -rf "/tmp/build/$pkg"
  mkdir -p "/tmp/build/$pkg"
  cd "/tmp/build/$pkg"

  if ! (apt-get source "${SRC_NAME}=${UPSTREAM_VER}" < /dev/null >> "$LOG_FILE" 2>&1 || apt-get source "$QUERY_PKG" < /dev/null >> "$LOG_FILE" 2>&1); then
    STEP_OK=0
  fi

  SRC_DIR="$(find "/tmp/build/$pkg" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ "$STEP_OK" -eq 1 && -z "$SRC_DIR" ]]; then
    echo "FEHLER: Kein Quellverzeichnis für $pkg in /tmp/build/$pkg gefunden!" >> "$LOG_FILE"
    STEP_OK=0
  fi

  if [[ "$STEP_OK" -eq 1 ]]; then
    cd "$SRC_DIR"

    # Globaler Schutz: Verhindert, dass Pakete in debian/rules (wie mesa oder re2) unser DEB_*FLAGS_MAINT_APPEND per := oder = überschreiben
    if [[ -f debian/rules ]]; then
      sed -E -i 's/^([[:space:]]*(export[[:space:]]+)?DEB_(C|CXX|LD)FLAGS_MAINT_APPEND[[:space:]]*):?=/\1+=/g' debian/rules || true
    fi

    # Paket-spezifische Upstream-/Debian-Rules-Quirks & Hardware-Pruning
    if [[ "$pkg" == "xz-utils" ]]; then
      sed -i 's/findstring nocheck/findstring nodoc/g' debian/rules || true
    elif [[ "$pkg" == "re2" ]]; then
      sed -i "s|export DEB_CXXFLAGS_MAINT_APPEND=.*|export DEB_CXXFLAGS_MAINT_APPEND=-pthread -Wall -std=c++14 ${ARCH_FLAGS} ${OPT_FLAGS}|" debian/rules || true
    elif [[ "$pkg" == "glibc" ]]; then
      # glibc nutzt in debian/rules eigenes HOST_CFLAGS statt dpkg-buildflags; nutze -march=armv8.2-a+... statt -mcpu=, damit libmvec SVE (-march=armv8-a+sve -Werror) konfliktfrei baut
      GLIBC_A76_FLAGS="-march=armv8.2-a+crypto+fp16+rcpc+dotprod -mtune=cortex-a76 -mno-fix-cortex-a53-835769 -mno-fix-cortex-a53-843419 -mbranch-protection=none -mno-outline-atomics -mearly-ra=all --param l1-cache-size=64 --param l1-cache-line-size=64 --param l2-cache-size=512 -Wno-error"
      sed -i "s|^HOST_CFLAGS =.*|HOST_CFLAGS = -pipe -O2 ${GLIBC_A76_FLAGS} -ftree-vectorize -fomit-frame-pointer -fno-math-errno -fdebug-prefix-map=\$(CURDIR)=. \$(call xx,extra_cflags)|" debian/rules || true
      grep -rl -- 'force-bti\|enable-bti' debian/ sysdeps/ Makeconfig configure* 2>/dev/null | xargs -r sed -i 's/--enable-bti/--disable-bti/g; s/-Wl,-z,force-bti,--fatal-warnings//g; s/-Wl,-z,force-bti//g; s/-z,force-bti//g; s/-z force-bti//g' || true
    elif [[ "$pkg" == "fastfetch" ]]; then
      # Deaktiviere Apple-Silicon Asahi-DRM-Check überall (CMakeLists.txt & __has_include in gpu_linux.c – inkompatibel mit RPi Linux 6.18 UAPI-Headern)
      grep -rl 'asahi_drm\.h' . 2>/dev/null | xargs -r sed -i 's|asahi_drm\.h|nonexistent_asahi_drm.h|g' || true
    elif [[ "$pkg" == "ksystemstats" ]]; then
      echo "   📊 Patche ksystemstats für Raspberry Pi 5 (/proc/cpuinfo EOF-Fix, cpu_thermal, SD/MMC Disk-Filter & Broadcom V3D GPU)..."
      python3 "$ROOT_DIR/patches/patch-ksystemstats-pi5.py" .
    elif [[ "$pkg" == "mesa" ]]; then
      echo "   🎨 Optimiere Mesa für Raspberry Pi 5 (V3D/VC4/Zink/LLVMpipe only – entferne AMD/Intel/Nvidia/Qualcomm/Mali/Asahi Ballast)..."
      sed -i 's/-Dbuild-tests=true/-Dbuild-tests=false/g' debian/rules || true
      sed -i '/^override_dh_auto_configure:/i GALLIUM_DRIVERS = softpipe llvmpipe virgl zink vc4 v3d\nVULKAN_DRIVERS = broadcom swrast virtio' debian/rules || true
      sed -i 's/-Dgallium-rusticl=true/-Dgallium-rusticl=false/g' debian/rules || true
      sed -i 's/-Dteflon=true/-Dteflon=false/g' debian/rules || true
      sed -i 's|mv debian/tmp/usr/lib/\${DEB_HOST_MULTIARCH}/dri/\*_drv_video.so|mv -f debian/tmp/usr/lib/\${DEB_HOST_MULTIARCH}/dri/\*_drv_video.so|g' debian/rules || true
      sed -i 's|debian/mesa-libgallium/usr/lib/\${DEB_HOST_MULTIARCH}/dri/|debian/mesa-libgallium/usr/lib/\${DEB_HOST_MULTIARCH}/dri/ 2>/dev/null \|\| true|g' debian/rules || true
      sed -i 's|mv debian/tmp/usr/share/drirc.d/|mv -f debian/tmp/usr/share/drirc.d/|g' debian/rules || true
      sed -i 's|debian/mesa-libgallium/usr/share/drirc.d/;|debian/mesa-libgallium/usr/share/drirc.d/ 2>/dev/null \|\| true;|g' debian/rules || true
      sed -i 's|debian/mesa-vulkan-drivers/usr/share/drirc.d/;|debian/mesa-vulkan-drivers/usr/share/drirc.d/ 2>/dev/null \|\| true;|g' debian/rules || true
      : > debian/mesa-opencl-icd.install 2>/dev/null || true
      : > debian/mesa-teflon-delegate.install 2>/dev/null || true
    elif [[ "$pkg" == "linux" ]]; then
      echo "   🐧 Konfiguriere Raspberry Pi 5 Kernel (rpi-2712 [16K] & rpi-v8 [4K], 1000 Hz, Cortex-A76 -O3, ohne Fremd-Errata & PAC/BTI)..."
      # 1. rpi-2712 (16K Standard) und rpi-v8 (4K für Box64/Wine/Emulatoren) bauen, nur v8-rt entfernen
      python3 - << 'PYEOF'
p = "debian/config/arm64/defines.toml"
with open(p) as f:
    txt = f.read()
txt = txt.replace("[[featureset.flavour]]\nname = 'v8-rt'\n", "")
with open(p, "w") as f:
    f.write(txt)
PYEOF
      # 2. 1000 Hz Timer, PAC/BTI aus und 29 fremde CPU-Errata in config.2712 UND config.v8 deaktivieren (nur echte Cortex-A76 Errata behalten)
      for kcfg in debian/config/arm64/rpi/config.2712 debian/config/arm64/rpi/config.v8; do
        [[ -f "$kcfg" ]] || continue
        cat << 'KCEOF' >> "$kcfg"
# KRubus Pi 5 / CM5 (BCM2712 Cortex-A76) Kernel Tuning
# CONFIG_HZ_250 is not set
CONFIG_HZ_1000=y
CONFIG_HZ=1000
# CONFIG_PSI_DEFAULT_DISABLED is not set
# CONFIG_ARM64_PTR_AUTH is not set
# CONFIG_ARM64_PTR_AUTH_KERNEL is not set
# CONFIG_ARM64_BTI is not set
# CONFIG_ARM64_BTI_KERNEL is not set
# CONFIG_ARM64_ERRATUM_826319 is not set
# CONFIG_ARM64_ERRATUM_827319 is not set
# CONFIG_ARM64_ERRATUM_824069 is not set
# CONFIG_ARM64_ERRATUM_819472 is not set
# CONFIG_ARM64_ERRATUM_832075 is not set
# CONFIG_ARM64_ERRATUM_834220 is not set
# CONFIG_ARM64_ERRATUM_1742098 is not set
# CONFIG_ARM64_ERRATUM_845719 is not set
# CONFIG_ARM64_ERRATUM_843419 is not set
# CONFIG_ARM64_ERRATUM_1024718 is not set
# CONFIG_ARM64_ERRATUM_1319367 is not set
# CONFIG_ARM64_ERRATUM_1530923 is not set
# CONFIG_ARM64_ERRATUM_2441007 is not set
# CONFIG_ARM64_ERRATUM_1542419 is not set
# CONFIG_ARM64_ERRATUM_1508412 is not set
# CONFIG_ARM64_ERRATUM_2051678 is not set
# CONFIG_ARM64_ERRATUM_2077057 is not set
# CONFIG_ARM64_ERRATUM_2658417 is not set
# CONFIG_ARM64_ERRATUM_2054223 is not set
# CONFIG_ARM64_ERRATUM_2067961 is not set
# CONFIG_ARM64_ERRATUM_2441009 is not set
# CONFIG_ARM64_ERRATUM_2457168 is not set
# CONFIG_ARM64_ERRATUM_2645198 is not set
# CONFIG_ARM64_ERRATUM_3821522 is not set
# CONFIG_ARM64_ERRATUM_2966298 is not set
# CONFIG_ARM64_ERRATUM_3117295 is not set
# CONFIG_ARM64_ERRATUM_3194386 is not set
# CONFIG_ARM64_ERRATUM_4193714 is not set
# CONFIG_ARM64_ERRATUM_4118414 is not set
# CONFIG_ARM64_ERRATUM_858921 is not set
KCEOF
      done
      # 3. Cortex-A76 -O3 Compiler-Flags direkt in KCFLAGS von debian/rules.real injizieren
      sed -i "s|KCFLAGS=-fdebug-prefix-map=\$(CURDIR)/=|KCFLAGS=\"-fdebug-prefix-map=\$(CURDIR)/= ${ARCH_FLAGS} -O3 -Wno-error\"|" debian/rules.real || true
      # 4. Absichtlichen exit 1 bei regenerierter debian/control in debian/rules neutralisieren
      sed -i '/debian\/control-real-fail:/,/^$/ s/exit 1/true/' debian/rules || true
    fi

    # Lokales Versions-Suffix (+pi5 / +pi5r1) exakt an den Changelog anhängen
    if ! DEBEMAIL="builder@localhost" DEBFULLNAME="KRubus Builder" dch --force-distribution -v "${TARGET_VER}" --distribution "${SUITE}" "Compiled for Raspberry Pi 5 Cortex-A76" < /dev/null >> "$LOG_FILE" 2>&1; then
      STEP_OK=0
    fi
  fi

  if [[ "$STEP_OK" -eq 1 ]]; then
    if [[ "$pkg" == "linux" ]]; then
      apt-get install -y --no-install-recommends python3-dacite python3-jinja2 quilt kernel-wedge bc bison flex libssl-dev libelf-dev kmod cpio pahole < /dev/null >> "$LOG_FILE" 2>&1 || true
      make -f debian/rules debian/control-real < /dev/null >> "$LOG_FILE" 2>&1 || true
    fi
    if ! (apt-get build-dep -y --allow-downgrades -P "${DEB_BUILD_PROFILES// /,}" ./ < /dev/null >> "$LOG_FILE" 2>&1 || apt-get build-dep -y --allow-downgrades -t trixie-backports -P "${DEB_BUILD_PROFILES// /,}" ./ < /dev/null >> "$LOG_FILE" 2>&1); then
      STEP_OK=0
    fi
  fi

  # Paket kompilieren mit 60-Sekunden-Heartbeat (inkl. 3-stufigem Self-Healing-Fallback: LTO -> Non-LTO -O3 -> Safe -O2 -B)
  if [[ "$STEP_OK" -eq 1 ]]; then
    BUILD_MODE="-b"
    [[ "$pkg" == "xz-utils" ]] && BUILD_MODE="-B"
    if ! run_dpkg_build_with_heartbeat "$pkg" "$CURRENT" "$TOTAL" "$LOG_FILE" "$BUILD_MODE"; then
      if [[ "$pkg" == "glibc" || "$pkg" == "linux" ]]; then
        STEP_OK=0
      elif [[ "$USE_LTO" -eq 1 ]]; then
        echo "   🔄 [$CURRENT/$TOTAL] LTO-Build für $pkg fehlgeschlagen – wiederhole automatisch ohne LTO (mit vollem $ARCH_FLAGS -O3)..."
        OPT_LEVEL="-O3"
        export DEB_CFLAGS_MAINT_APPEND="$ARCH_FLAGS $OPT_FLAGS"
        export DEB_CXXFLAGS_MAINT_APPEND="$ARCH_FLAGS $OPT_FLAGS"
        export DEB_LDFLAGS_MAINT_APPEND="$PKG_LINK_FLAGS"
        debian/rules clean < /dev/null >> "$LOG_FILE" 2>&1 || true
        if ! run_dpkg_build_with_heartbeat "$pkg" "$CURRENT" "$TOTAL" "$LOG_FILE" "$BUILD_MODE"; then
          echo "   🔄 [$CURRENT/$TOTAL] Build (-b) für $pkg fehlgeschlagen – wiederhole mit Safe-Cortex-A76 (-O2 -B)..."
          OPT_LEVEL="-O2"
          export DEB_CFLAGS_MAINT_APPEND="$ARCH_FLAGS $SAFE_OPT_FLAGS"
          export DEB_CXXFLAGS_MAINT_APPEND="$ARCH_FLAGS $SAFE_OPT_FLAGS"
          export DEB_LDFLAGS_MAINT_APPEND="$PKG_LINK_FLAGS"
          debian/rules clean < /dev/null >> "$LOG_FILE" 2>&1 || true
          if ! run_dpkg_build_with_heartbeat "$pkg" "$CURRENT" "$TOTAL" "$LOG_FILE" "-B"; then
            STEP_OK=0
          fi
        fi
      else
        echo "   🔄 [$CURRENT/$TOTAL] Build (-b) für $pkg fehlgeschlagen – wiederhole automatisch mit Safe-Cortex-A76 (-O2 -B)..."
        OPT_LEVEL="-O2"
        export DEB_CFLAGS_MAINT_APPEND="$ARCH_FLAGS $SAFE_OPT_FLAGS"
        export DEB_CXXFLAGS_MAINT_APPEND="$ARCH_FLAGS $SAFE_OPT_FLAGS"
        export DEB_LDFLAGS_MAINT_APPEND="$PKG_LINK_FLAGS"
        debian/rules clean < /dev/null >> "$LOG_FILE" 2>&1 || true
        if ! run_dpkg_build_with_heartbeat "$pkg" "$CURRENT" "$TOTAL" "$LOG_FILE" "-B"; then
          STEP_OK=0
        fi
      fi
    fi
  fi

  # Debug-, Doku-, Test- und Cross-Compile-Ballast löschen, .deb-Pakete direkt in den Pool verschieben und lokalen APT-Index aktualisieren
  if [[ "$STEP_OK" -eq 1 ]]; then
    rm -f ../*dbgsym*.deb \
          ../*-dbg_*.deb \
          ../*.ddeb \
          ../*-doc_*.deb \
          ../*-docs_*.deb \
          ../*-examples_*.deb \
          ../*-tests_*.deb \
          ../*-source_*.deb \
          ../*-mingw-*.deb \
          ../locales-all_*.deb \
          ../nscd_*.deb
    if compgen -G "../*.deb" > /dev/null; then
      mv -f ../*.deb "$REPO_DIR/pool/main/"
      update_local_apt_repo
    else
      STEP_OK=0
    fi
  fi

  cd "$ROOT_DIR"
  rm -rf "/tmp/build/$pkg"
  DURATION=$(( $(date +%s) - PKG_START_TIME ))

  if [[ "$STEP_OK" -ne 1 ]]; then
    echo "[$(date -u '+%H:%M:%S')] ❌ [$CURRENT/$TOTAL] Fehler bei $pkg nach ${DURATION}s! Letzte 100 Zeilen aus $LOG_FILE:"
    echo "--------------------------------------------------------------------"
    tail -n 100 "$LOG_FILE" || true
    echo "--------------------------------------------------------------------"
    echo "| $CURRENT/$TOTAL | \`$pkg\` | \`$TARGET_VER\` | \`$OPT_LEVEL\` | ❌ Fehler | ${DURATION}s |" >> "$SUMMARY_FILE"
    BUILD_FAILED=1
    continue
  fi

  rm -f "$LOG_FILE"
  echo "[$(date -u '+%H:%M:%S')] ✅ [$CURRENT/$TOTAL] $pkg fertig gebaut in ${DURATION}s"
  echo "| $CURRENT/$TOTAL | \`$pkg\` | \`$TARGET_VER\` | \`$OPT_LEVEL\` | ✅ Gebaut | ${DURATION}s |" >> "$SUMMARY_FILE"

done 3< "$BUILD_QUEUE"
rm -f "$BUILD_QUEUE"
