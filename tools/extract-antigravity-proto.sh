#!/usr/bin/env bash
#
# extract-antigravity-proto.sh — Phase 7 (ACP harness) spike tool.
#
# Recovers the Antigravity `language_server` gRPC schema needed to OBSERVE a
# Gemini/Antigravity turn at high fidelity (plan / diff / tool-call / permission
# steps) so the Phase-7 `AntigravityAgentAPIDriver` can map those steps onto the
# unified `HarnessEvent` contract — the same shape the ACP mapper produces.
#
# Why this works: `language_server` is a Go binary built with the modern
# protobuf runtime (`*_go_proto`), so it embeds (a) ~945 `.proto` file paths,
# (b) the full set of `protobuf:"..."` struct tags (field name + number + wire
# type + json name) for every generated message, and (c) the gRPC service +
# method names. The struct tags ARE the schema — they are the authoritative,
# always-recoverable field map for this binary, regardless of whether the
# serialized FileDescriptorProtos can be cleanly carved out.
#
# Verified live 2026-06-02 (see docs/acp-harness/phase7-grpc-spike.md):
#   service  google.internal.cloud.code.v1internal.JetskiService
#   stream   GenerateChatResponse (server-streaming)  +  TabChatResponse
#   steps    third_party/gemini_coder/cider/proto/trajectory_steps.proto
#   fields   is_permission(3) tool_call_id tool_call_json(2) unified_diff
#            diff_outline ApprovalType PermissionId preapprovals(1,2) step_payload
#   reflection: NOT compiled in -> static extraction (this script), not grpcurl.
#
# Usage:
#   tools/extract-antigravity-proto.sh [path/to/Antigravity.app] [out-dir]
# Defaults: /Applications/Antigravity.app  ->  docs/acp-harness/antigravity-proto/
#
# Outputs (in out-dir):
#   proto-inventory.txt    every embedded .proto path (the 945)
#   field-map.txt          every protobuf struct tag (the usable schema)
#   v1internal-fields.txt  struct tags scoped to the v1internal / agent / step
#                          / diff / permission surface we map to HarnessEvent
#   rpc-methods.txt        the gRPC service/method paths (/pkg.Service/Method)
#   descriptors/*.fdp.txt  best-effort protoc --decode of carved FileDescriptors
#
set -euo pipefail

APP="${1:-/Applications/Antigravity.app}"
OUT="${2:-docs/acp-harness/antigravity-proto}"
LS="$APP/Contents/Resources/bin/language_server"

if [[ ! -x "$LS" ]]; then
  echo "error: language_server not found at $LS" >&2
  echo "       pass the Antigravity.app path as \$1 (is Antigravity installed?)" >&2
  exit 1
fi
mkdir -p "$OUT" "$OUT/descriptors"

echo "==> language_server: $LS ($(du -h "$LS" | cut -f1))"

# 1) Proto file inventory — proves the schema is compiled in + lists every file.
strings -n 8 "$LS" | grep -aE '\.proto$' | sort -u > "$OUT/proto-inventory.txt"
echo "==> proto-inventory.txt: $(wc -l < "$OUT/proto-inventory.txt" | tr -d ' ') proto paths"

# 2) Field map — the authoritative schema for a Go binary: every struct tag
#    carries name + field number + wire type + json name (and, for messages,
#    the nested type). This is what you transcribe into the Swift decoder.
strings -n 12 "$LS" | grep -aoE 'protobuf:"[^"]*"[^"]*json:"[^"]*"' | sort -u > "$OUT/field-map.txt" || true
echo "==> field-map.txt: $(wc -l < "$OUT/field-map.txt" | tr -d ' ') struct tags"

# 3) The surface we actually map to HarnessEvent: chat/step/diff/tool/permission.
grep -aiE 'step_payload|tool_call|unified_diff|diff_outline|FileDiff|is_permission|ApprovalType|PermissionId|preapprovals|trajectory|cascade|GenerateChat' \
  "$OUT/field-map.txt" | sort -u > "$OUT/v1internal-fields.txt" || true
echo "==> v1internal-fields.txt: $(wc -l < "$OUT/v1internal-fields.txt" | tr -d ' ') step/diff/permission/tool fields"

# 4) gRPC service + method paths (/package.Service/Method).
strings -n 12 "$LS" | grep -aoE '/[a-z0-9_.]+\.[A-Za-z0-9]+(Service|ServerService)/[A-Za-z0-9]+' | sort -u > "$OUT/rpc-methods.txt" || true
echo "==> rpc-methods.txt: $(wc -l < "$OUT/rpc-methods.txt" | tr -d ' ') RPC method paths"

# 5) Best-effort FileDescriptorProto carve + decode for the key files. The Go
#    runtime stores each file's serialized FileDescriptorProto (rawDesc); a
#    FileDescriptorProto begins with field 1 (name) = tag 0x0a, a varint length,
#    then the path string. We locate that marker and let protoc grow the window
#    until it decodes. Requires `protoc` (libprotoc). This is a BONUS on top of
#    the struct-tag field map above, which is the reliable source of truth.
if command -v protoc >/dev/null 2>&1; then
  echo "==> protoc $(protoc --version): attempting descriptor carve (best-effort)"
  # protoc bundles descriptor.proto under its include dir; locate it.
  PROTO_INC="$(dirname "$(command -v protoc)")/../include"
  for target in \
    "google/internal/cloud/code/v1internal/jetski_service.proto" \
    "third_party/gemini_coder/cider/proto/trajectory_steps.proto" \
    "third_party/jetski/language_server_pb/language_server.proto"; do
    safe="$(echo "$target" | tr '/.' '__')"
    # Byte offset of the path string in the binary.
    off=$(grep -aboF "$target" "$LS" | head -1 | cut -d: -f1 || true)
    [[ -z "${off:-}" ]] && { echo "    - $target: path marker not found"; continue; }
    # The 0x0a + varint length sits 1-2 bytes before the string; back up a few
    # bytes and let protoc --decode try increasing windows (8KB..512KB).
    start=$(( off > 2 ? off - 2 : 0 ))
    decoded=""
    for win in 8192 32768 131072 524288; do
      if dd if="$LS" bs=1 skip="$start" count="$win" status=none 2>/dev/null \
          | protoc --decode=google.protobuf.FileDescriptorProto \
              -I"$PROTO_INC" "$PROTO_INC/google/protobuf/descriptor.proto" \
              > "$OUT/descriptors/$safe.fdp.txt" 2>/dev/null; then
        if [[ -s "$OUT/descriptors/$safe.fdp.txt" ]]; then decoded="$win"; break; fi
      fi
    done
    if [[ -n "$decoded" ]]; then
      echo "    - $target: decoded (window=${decoded}B) -> descriptors/$safe.fdp.txt"
    else
      rm -f "$OUT/descriptors/$safe.fdp.txt"
      echo "    - $target: carve inconclusive (use field-map.txt — the struct tags are authoritative)"
    fi
  done
else
  echo "==> protoc not found — skipping descriptor carve; field-map.txt is the schema source."
fi

echo "==> done. Schema artifacts in: $OUT"
echo "    Implement Phase 7 against rpc-methods.txt (JetskiService streaming) +"
echo "    v1internal-fields.txt (step/diff/permission/tool field numbers)."
