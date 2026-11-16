#!/usr/bin/env bash
# Подготовка версии, заметок и подписи релиза 3X-UI KIT CUSTOM.
# Справка: tools/release.sh --help

set -euo pipefail
caller_dir=$PWD
cd "$(dirname "$0")/.."

die() { printf '✗  %s\n' "$*" >&2; exit 1; }
ok()  { printf '✓  %s\n' "$*"; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
# Скачивание с GitHub: сеть бывает нестабильной, поэтому несколько попыток, а при неудаче – понятное сообщение
# (раньше скрипт молча останавливался на случайном месте).
get() { curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 "$1" || { echo "✗  Не скачалось с GitHub: $1 (сеть нестабильна: повторите запуск или включите VPN)" >&2; return 1; }; }

NS="3x-ui-kit-release"
ID="releases@3x-ui-kit"
VERSIONED=(scripts/3x-ui.sh scripts/hysteria2.sh scripts/kit.sh)
FILES=("${VERSIONED[@]}" scripts/kit-sub.py VERSION)

usage() {
  cat <<'EOF'
Использование:
  tools/release.sh prepare <версия> [база]   Обновить VERSION, скрипты и CHANGELOG.md.
  tools/release.sh notes [версия]            Вывести описание выпуска из CHANGELOG.md.
  tools/release.sh sign [закрытый-ключ]       Проверить зависимости и подписать SHA256SUMS.
  tools/release.sh verify                    Проверить SHA256SUMS и подпись для текущих файлов.

Версия задаётся в формате X.Y.Z (с v или без). База — тег, ветка или коммит.
По умолчанию используется ближайший достижимый тег vX.Y.Z.
Подпись использует ~/.ssh/3xui_kit_custom_release, если путь не задан.
EOF
}

valid_version() {
  [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

release_notes() {
  local version=${1#v}
  valid_version "$version" || die "Некорректная версия: $version"
  awk -v version="v$version" '
    /^## / {
      if (found) exit
      heading = substr($0, 4)
      if (heading != version && index(heading, version ":") != 1 &&
          index(heading, version " ") != 1) next
      found = 1
      next
    }
    found && (printed || NF) {
      if (NF) {
        if (gap) printf "%s", gap
        print
        printed = 1
        gap = ""
      } else gap = gap "\n"
    }
    END { if (!printed) exit 1 }
  ' CHANGELOG.md || die "Нет содержимого раздела ## $version в CHANGELOG.md."
}

prepare() (
  local target=${1#v} base=${2:-} current file temp
  valid_version "$target" || die "Некорректная версия: $target"
  current=$(cat VERSION)
  valid_version "$current" || die "Некорректная версия в VERSION: $current"
  git show-ref --verify --quiet "refs/tags/v$target" && die "Тег v$target уже существует."
  [[ $current != "$target" && $(printf '%s\n' "$current" "$target" | sort -V | tail -1) == "$target" ]] \
    || die "Новая версия должна быть выше $current."
  [[ -z $(git status --porcelain -- VERSION CHANGELOG.md "${VERSIONED[@]}") ]] \
    || die "Сначала сохрани изменения в VERSION, CHANGELOG.md и скриптах."
  if [[ -z $base ]]; then
    base=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null) \
      || die "Не найден базовый тег. Укажи базовый коммит явно."
    valid_version "${base#v}" || die "Ближайший тег $base. Укажи базовый тег или коммит явно."
  fi
  base=$(git rev-parse --verify --end-of-options "$base^{commit}") || die "База не найдена."
  git merge-base --is-ancestor "$base" HEAD || die "Базовый коммит должен входить в историю HEAD."
  for file in "${VERSIONED[@]}"; do
    grep -qxF "KIT_VERSION=\"$current\"" "$file" || die "$file: KIT_VERSION расходится с VERSION."
  done
  temp=$(mktemp -d "./.release-prepare.XXXXXX")
  trap 'rm -rf -- "$temp"' EXIT
  if ! awk -v v="v$target" '$1 == "##" && ($2 == v || $2 == v ":") { found = 1 } END { exit !found }' CHANGELOG.md; then
    local entries
    entries=$(git log --no-merges --format='- %s (%h)' "$base..HEAD")
    [[ -n $entries ]] || die "После базового коммита нет изменений для changelog."
    {
      head -n 1 CHANGELOG.md
      printf '\n## v%s\n\n%s\n' "$target" "$entries"
      tail -n +2 CHANGELOG.md
    } > "$temp/CHANGELOG.md"
  fi
  printf '%s\n' "$target" > "$temp/VERSION"
  for file in "${VERSIONED[@]}"; do
    cp -p "$file" "$temp/${file##*/}"
    sed "s/^KIT_VERSION=.*$/KIT_VERSION=\"$target\"/" "$file" > "$temp/${file##*/}"
  done
  for file in VERSION "${VERSIONED[@]}"; do
    mv -f "$temp/${file##*/}" "$file"
  done
  if [[ -f $temp/CHANGELOG.md ]]; then mv -f "$temp/CHANGELOG.md" CHANGELOG.md; fi
  ok "Версия v$target и черновик changelog готовы. Проверь git diff и закоммить изменения."
)

check_release_version() {
  local file version
  version=$(cat VERSION)
  valid_version "$version" || die "Некорректная версия в VERSION: $version"
  for file in "${VERSIONED[@]}"; do
    grep -qxF "KIT_VERSION=\"$version\"" "$file" || die "$file: KIT_VERSION расходится с VERSION."
  done
  release_notes "$version" >/dev/null
}

manifest() {
  printf '# 3X-UI KIT %s\n' "$(cat VERSION)"
  sha "${FILES[@]}"
}

signers() { awk '/^KIT_SIGNERS=\(/ {on = 1; next} on && /^\)/ {exit} on && /^ *"/ {gsub(/^ *"|"$/, ""); print}' scripts/kit.sh; }

verify_signature() {
  local manifest_file=$1 allowed_signers=$2 key
  while IFS= read -r key; do
    printf '%s namespaces="%s" %s\n' "$ID" "$NS" "$key"
  done < <(signers) > "$allowed_signers"
  [[ -s $allowed_signers ]] || die "В scripts/kit.sh пустой KIT_SIGNERS."
  ssh-keygen -Y verify -f "$allowed_signers" -I "$ID" -n "$NS" -s "$manifest_file.sig" < "$manifest_file"
}

verify() (
  check_release_version
  local temp
  temp=$(mktemp -d)
  trap 'rm -rf -- "$temp"' EXIT
  [[ -s SHA256SUMS && -s SHA256SUMS.sig ]] || die "Нет SHA256SUMS или SHA256SUMS.sig."
  manifest > "$temp/SHA256SUMS"
  cmp -s "$temp/SHA256SUMS" SHA256SUMS || die "SHA256SUMS расходится с текущими файлами релиза."
  verify_signature SHA256SUMS "$temp/allowed_signers" || die "Подпись не прошла проверку."
)

check_dependencies() {
  local xv xs got xc a pin off kp kx shs
  # Установщик 3X-UI: хеш в скрипте должен совпадать с тем, что сейчас лежит на GitHub.
  xv=$(sed -n 's/^XUI_VERSION="\(.*\)"/\1/p' scripts/3x-ui.sh)
  xs=$(sed -n 's/^XUI_INSTALL_SHA256="\(.*\)"/\1/p' scripts/3x-ui.sh)
  got=$(get "https://raw.githubusercontent.com/MHSanaei/3x-ui/$xv/install.sh" | sha | awk '{print $1}')
  [[ $got == "$xs" ]] || die "Установщик 3X-UI $xv изменился: $got вместо $xs. Проверьте, что поменялось, прежде чем выпускать."
  ok "Установщик 3X-UI $xv совпадает с закреплённым SHA256"

  # Суммы архивов ядра Xray в скрипте должны совпадать с официальными (.dgst релиза Xray-core).
  xc=$(sed -n 's/^XRAY_CORE="\(.*\)"/\1/p' scripts/3x-ui.sh)
  for a in 64 arm64-v8a; do
    pin=$(sed -n "s/^  \[$a\]=\([0-9a-f]\{64\}\)\$/\1/p" scripts/3x-ui.sh)
    off=$(get "https://github.com/XTLS/Xray-core/releases/download/$xc/Xray-linux-$a.zip.dgst" | awk '/^SHA2-256=/ {print $2}')
    [[ -n $pin && $pin == "$off" ]] || die "Сумма ядра Xray $xc ($a) в 3x-ui.sh не совпадает с официальной: «$pin» вместо «$off»."
  done
  ok "Суммы архивов ядра Xray $xc совпадают с официальными"

  # Проверенная панель и ядро в kit.sh (kit panel update, kit check): те же версии, что в установщике,
  # а суммы архива панели и скрипта меню x-ui – официальные.
  kp=$(sed -n 's/^XUI_PIN="\(.*\)"/\1/p' scripts/kit.sh)
  [[ $kp == "$xv" ]] || die "XUI_PIN в kit.sh ($kp) не совпадает с XUI_VERSION в 3x-ui.sh ($xv)."
  kx=$(sed -n 's/^XRAY_PIN="\(.*\)"/\1/p' scripts/kit.sh)
  [[ $kx == "$xc" ]] || die "XRAY_PIN в kit.sh ($kx) не совпадает с XRAY_CORE в 3x-ui.sh ($xc)."
  for a in amd64 arm64; do
    pin=$(sed -n "s/^  \[$a\]=\([0-9a-f]\{64\}\)\$/\1/p" scripts/kit.sh)
    off=$(get "https://github.com/MHSanaei/3x-ui/releases/download/$kp/x-ui-linux-$a.tar.gz.sha256" | awk 'NR == 1 {print $1}')
    [[ -n $pin && $pin == "$off" ]] || die "Сумма архива панели $kp ($a) в kit.sh не совпадает с официальной: «$pin» вместо «$off»."
  done
  shs=$(sed -n 's/^XUI_SH_SHA256=\(.*\)/\1/p' scripts/kit.sh)
  got=$(get "https://raw.githubusercontent.com/MHSanaei/3x-ui/$kp/x-ui.sh" | sha | awk '{print $1}')
  [[ $shs == "$got" ]] || die "Сумма x-ui.sh $kp в kit.sh не совпадает с официальной: «$shs» вместо «$got»."
  ok "Панель $kp и ядро $kx в kit.sh совпадают с установщиком и официальными суммами"
}

sign() (
  check_release_version
  [[ -z $(git status --porcelain -- "${FILES[@]}" CHANGELOG.md) ]] \
    || die "Сначала закоммить файлы релиза и CHANGELOG.md."
  local key=${1:-$HOME/.ssh/3xui_kit_custom_release} pub temp
  [[ $key = /* || $key == [A-Za-z]:/* ]] || key="$caller_dir/$key"
  [[ -f $key ]] || die "Нет закрытого ключа: $key"
  if [[ -r $key.pub ]]; then
    pub=$(awk 'NR == 1 { print $1, $2 }' "$key.pub")
  else
    pub=$(ssh-keygen -y -f "$key" | awk '{print $1, $2}')
  fi
  signers | awk '{print $1, $2}' | grep -xF "$pub" >/dev/null \
    || die "Открытого ключа нет в KIT_SIGNERS."
  check_dependencies
  temp=$(mktemp -d "./.release-sign.XXXXXX")
  trap 'rm -rf -- "$temp"' EXIT
  manifest > "$temp/SHA256SUMS"
  ssh-keygen -Y sign -f "$key" -n "$NS" "$temp/SHA256SUMS"
  verify_signature "$temp/SHA256SUMS" "$temp/allowed_signers" || die "Подпись не прошла проверку."
  mv -f "$temp/SHA256SUMS" "$temp/SHA256SUMS.sig" .
  ok "Манифест подписан. Проверь и закоммить SHA256SUMS и SHA256SUMS.sig."
)

case ${1:-sign} in
  prepare) [[ $# -ge 2 && $# -le 3 ]] || die "Использование: prepare <версия> [база]"; prepare "${@:2}" ;;
  notes) [[ $# -le 2 ]] || die "Использование: notes [версия]"; release_notes "${2:-$(cat VERSION)}" ;;
  sign) [[ $# -le 2 ]] || die "Использование: sign [закрытый-ключ]"; sign "${2:-}" ;;
  verify) [[ $# -eq 1 ]] || die "Использование: verify"; verify ;;
  -h | --help) usage ;;
  *)
    [[ $# -eq 1 && ( -f $caller_dir/$1 || -f $1 ) ]] || die "Неизвестная команда: $1. См. --help."
    sign "$1"
    ;;
esac
