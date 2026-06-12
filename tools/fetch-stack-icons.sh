#!/usr/bin/env bash
# Downloads the 50 most popular dev-stack logos from simple-icons (MIT)
# and generates StackIcons.xcassets for ClawdmeterShared.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/apple/ClawdmeterShared/Sources/ClawdmeterShared/Icons/StackIcons.xcassets"
CDN="https://cdn.jsdelivr.net/npm/simple-icons@11.14.0/icons"
VERSION="11.14.0"

# slug:asset-name pairs — asset names are stack-{slug} for stable Swift lookups
STACKS=(
  javascript
  typescript
  python
  swift
  go
  rust
  ruby
  openjdk
  kotlin
  csharp
  cplusplus
  c
  php
  dart
  scala
  html5
  css3
  react
  vuedotjs
  angular
  nextdotjs
  nodedotjs
  svelte
  docker
  kubernetes
  terraform
  amazonaws
  postgresql
  mysql
  mongodb
  redis
  graphql
  tailwindcss
  flutter
  dotnet
  nginx
  vite
  webpack
  git
  markdown
  yaml
  gnubash
  powershell
  lua
  elixir
  haskell
  zig
  deno
  bun
  githubactions
)

mkdir -p "$ASSETS"

cat > "$ASSETS/Contents.json" <<'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

for slug in "${STACKS[@]}"; do
  asset="stack-${slug}"
  dir="$ASSETS/${asset}.imageset"
  mkdir -p "$dir"
  svg="$dir/${slug}.svg"
  url="$CDN/${slug}.svg"
  echo "Fetching $slug ..."
  curl -fsSL "$url" -o "$svg"
  cat > "$dir/Contents.json" <<EOF
{
  "images" : [
    {
      "filename" : "${slug}.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "original"
  }
}
EOF
done

echo "Downloaded ${#STACKS[@]} stack icons into $ASSETS (simple-icons v${VERSION})"
