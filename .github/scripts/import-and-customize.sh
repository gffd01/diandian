#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(git rev-parse --show-toplevel)
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

backend_dir="$temp_dir/s-ui"
frontend_dir="$temp_dir/s-ui-frontend"

git clone --depth 1 https://github.com/Teminuosi/s-ui.git "$backend_dir"
git clone --depth 1 https://github.com/Teminuosi/s-ui-frontend.git "$frontend_dir"

backend_sha=$(git -C "$backend_dir" rev-parse HEAD)
frontend_sha=$(git -C "$frontend_dir" rev-parse HEAD)

# Keep this repository's release/bootstrap automation and clean README while
# replacing the product source with the newest Teminuosi backend.
rsync -a --delete \
  --exclude .git \
  --exclude .github/workflows \
  --exclude .github/scripts \
  --exclude README.md \
  "$backend_dir/" "$repo_root/"

# The upstream backend uses the frontend as a submodule. This clean repository
# vendors it as ordinary source so every source modification remains visible.
mkdir -p "$repo_root/frontend"
rsync -a --delete --exclude .git "$frontend_dir/" "$repo_root/frontend/"
rm -f "$repo_root/.gitmodules"

REPO_ROOT="$repo_root" BACKEND_SHA="$backend_sha" FRONTEND_SHA="$frontend_sha" python3 <<'PY'
import os
from pathlib import Path

root = Path(os.environ["REPO_ROOT"])


def replace_once(relative_path: str, old: str, new: str) -> None:
    path = root / relative_path
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected one matching promotion block in {relative_path}, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


replace_once(
    "frontend/src/layouts/default/Drawer.vue",
    '''      <v-list-item prepend-icon="mdi-web" :title="$t('menu.site')"
        href="https://3yuedaohang.com" target="_blank" rel="noopener noreferrer"></v-list-item>
      <v-list-item prepend-icon="mdi-youtube" :title="$t('menu.youtube')"
        href="https://www.youtube.com/@zhanzhang3yue" target="_blank" rel="noopener noreferrer"></v-list-item>
      <v-list-item prepend-icon="mdi-server" :title="$t('menu.vps')"
        href="https://3yuedaohang.com/cn2/banwagong" target="_blank" rel="noopener noreferrer"></v-list-item>
''',
    "",
)

replace_once(
    "frontend/src/views/Login.vue",
    '''              <div class="text-center mt-3">
                <a href="https://3yuedaohang.com" target="_blank" rel="noopener noreferrer"
                  class="text-caption text-decoration-none">🌐 {{ $t('menu.site') }} · 3yuedaohang.com</a>
                <br>
                <a href="https://www.youtube.com/@zhanzhang3yue" target="_blank" rel="noopener noreferrer"
                  class="text-caption text-decoration-none">📺 {{ $t('menu.youtube') }} · @zhanzhang3yue</a>
                <br>
                <a href="https://3yuedaohang.com/cn2/banwagong" target="_blank" rel="noopener noreferrer"
                  class="text-caption text-decoration-none">🖥️ {{ $t('menu.vps') }}</a>
              </div>
''',
    "",
)

replace_once(
    "frontend/src/locales/en.ts",
    '''    site: "Blog",
    youtube: "YouTube",
    vps: "VPS picks",
''',
    "",
)

replace_once(
    "frontend/src/locales/zhcn.ts",
    '''    site: "站长博客",
    youtube: "YouTube 频道",
    vps: "机器推荐",
''',
    "",
)

installer = root / "install.sh"
install_text = installer.read_text(encoding="utf-8")
replacements = {
    "https://raw.githubusercontent.com/Teminuosi/s-ui/": "https://raw.githubusercontent.com/gffd01/diandian/",
    "https://api.github.com/repos/Teminuosi/s-ui/releases": "https://api.github.com/repos/gffd01/diandian/releases",
    "https://github.com/Teminuosi/s-ui/releases/download": "https://github.com/gffd01/diandian/releases/download",
}
for old, new in replacements.items():
    if old not in install_text:
        raise SystemExit(f"Expected installer reference was not found: {old}")
    install_text = install_text.replace(old, new)

if 'SUI_AUTO="${SUI_AUTO:-1}"' not in install_text:
    raise SystemExit("Upstream SUI_AUTO=1 automatic installation logic was not found")
if "Teminuosi/s-ui/releases" in install_text:
    raise SystemExit("An upstream release URL remains in install.sh")
installer.write_text(install_text, encoding="utf-8")

blocked = ("3yuedaohang", "zhanzhang3yue", "banwagong")
for path in (root / "frontend" / "src").rglob("*"):
    if not path.is_file():
        continue
    text = path.read_text(encoding="utf-8", errors="ignore").lower()
    for token in blocked:
        if token in text:
            raise SystemExit(f"Promotional token {token!r} remains in {path.relative_to(root)}")

(root / ".upstream-versions").write_text(
    f"Teminuosi/s-ui {os.environ['BACKEND_SHA']}\n"
    f"Teminuosi/s-ui-frontend {os.environ['FRONTEND_SHA']}\n",
    encoding="utf-8",
)
PY

chmod +x "$repo_root/install.sh" "$repo_root/s-ui.sh" "$repo_root/.github/scripts/import-and-customize.sh"

bash -n "$repo_root/install.sh"
bash -n "$repo_root/s-ui.sh"

echo "Imported backend:  $backend_sha"
echo "Imported frontend: $frontend_sha"
