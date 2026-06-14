#!/bin/bash
set -e

BOOT_LOG="$HOME/boot.log"
exec > >(tee "$BOOT_LOG") 2>&1
echo "=== exedev-bootstrap.sh started at $(date) ==="

ACCESS_TOKEN=auhYffpbliMIP26zylFnojCoSJ0wHhHWqw6hQhaq
CCPROXY_CONFIG="$HOME/.config/ccproxy/config.toml"
CCPROXY_PORT=8585
SHELLEY_DIR="$HOME/shelley"
SHELLEY_PORT=9000

# === Non-interactive environment ===
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_SUSPEND=1
export NEEDRESTART_MODE=a
export GIT_TERMINAL_PROMPT=0
APT_FLAGS="-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    -o Acquire::Retries=3 -o Acquire::http::Timeout=30"

# === Detect architecture ===
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  GO_ARCH="amd64";  NODE_ARCH="x64";   ;;
    aarch64) GO_ARCH="arm64";  NODE_ARCH="arm64";  ;;
    armv7l)  GO_ARCH="armv6l"; NODE_ARCH="armv7l"; ;;
    *)       echo "ERROR: Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

# /etc/os-release exposes ID ("ubuntu", "debian", ...) and ID_LIKE on all
# systemd distros. The chromium package differs: Ubuntu & derivatives ship a
# transitional "chromium-browser" (snap-backed); Debian ships real "chromium".
OS_ID=""
OS_ID_LIKE=""
if [ -r /etc/os-release ]; then
    OS_ID=$(. /etc/os-release 2>/dev/null && echo "$ID")
    OS_ID_LIKE=$(. /etc/os-release 2>/dev/null && echo "$ID_LIKE")
fi
case "$OS_ID" in
    ubuntu|linuxmint|pop|elementary|zorin|neon) CHROMIUM_PKG="chromium-browser" ;;
    debian|raspbian|kali|devuan)                CHROMIUM_PKG="chromium" ;;
    *)
        case "$OS_ID_LIKE" in
            *ubuntu*) CHROMIUM_PKG="chromium-browser" ;;
            *)        CHROMIUM_PKG="chromium" ;;
        esac
        ;;
esac
echo ">>> OS: ${OS_ID:-unknown} (like: ${OS_ID_LIKE:-n/a}) | Arch: $ARCH" \
     "(Go: $GO_ARCH, Node: $NODE_ARCH) | chromium pkg: $CHROMIUM_PKG"

# === Install system dependencies ===
# chromium + ffmpeg are required by shelley's browser tool:
# chromium drives the headless browser, ffmpeg encodes the screencast stream.
# $CHROMIUM_PKG is resolved above per-distro.
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
    apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=a \
    apt-get $APT_FLAGS upgrade || true
_apt_need=()
for _pkg in python3-pip screen make build-essential curl git wget xz-utils ripgrep ffmpeg qrencode "$CHROMIUM_PKG"; do
    dpkg -s "$_pkg" &>/dev/null 2>&1 || _apt_need+=("$_pkg")
done
if [ ${#_apt_need[@]} -gt 0 ]; then
    sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=a \
        apt-get $APT_FLAGS install "${_apt_need[@]}"
fi
unset _apt_need _pkg

# === Install Go from go.dev ===
GO_VERSION=$(curl -s "https://go.dev/dl/?mode=json" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['version'])")
echo ">>> Latest Go: $GO_VERSION for linux/$GO_ARCH"
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "$GO_VERSION"; then
    echo ">>> Installing $GO_VERSION..."
    curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    rm -f /tmp/go.tar.gz
fi
export PATH="/usr/local/go/bin:$PATH"
go version

# === Install Node.js 22 (pnpm requires >=22) ===
NODE_VERSION="22.16.0"
if ! node --version 2>/dev/null | grep -q "^v${NODE_VERSION}$"; then
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
        -o /tmp/node22.tar.xz
    sudo tar -xJf /tmp/node22.tar.xz -C /usr/local --strip-components=1
    rm -f /tmp/node22.tar.xz
fi
node --version

command -v pnpm &>/dev/null || sudo npm install -g pnpm

python3 -c "import ccproxy" &>/dev/null 2>&1 || \
    pip3 install "ccproxy-api[all]" -q --break-system-packages 2>/dev/null || \
    pip3 install "ccproxy-api[all]" -q

# pip installs scripts to ~/.local/bin which may not be on PATH
export PATH="$HOME/.local/bin:$PATH"

# === Patch ccproxy: use <think> tags, expose ThinkingBlock in RequestContentBlock ===
cat > /tmp/patch_ccproxy.py << 'PYEOF'
import ccproxy, os, sys

pkg = os.path.dirname(ccproxy.__file__) if getattr(ccproxy, "__file__", None) else next(iter(ccproxy.__path__))

def patch(path, old, new, label):
    with open(path) as f:
        src = f.read()
    if old not in src:
        print(f"SKIP (already applied or not found): {label}", file=sys.stderr)
        return
    with open(path, "w") as f:
        f.write(src.replace(old, new, 1))
    print(f"Patched: {label}")

responses_py = os.path.join(pkg, "llms/formatters/anthropic_to_openai/responses.py")
streams_py   = os.path.join(pkg, "llms/formatters/anthropic_to_openai/streams.py")
anthropic_py = os.path.join(pkg, "llms/models/anthropic.py")

# responses.py — first thinking block (convert__anthropic_message_to_openai_responses__response)
patch(responses_py,
    '        elif block_type == "thinking":\n'
    '            thinking = getattr(block, "thinking", None) or ""\n'
    '            signature = getattr(block, "signature", None)\n'
    '            sig_attr = (\n'
    '                f\' signature="{signature}"\'\n'
    '                if isinstance(signature, str) and signature\n'
    '                else ""\n'
    '            )\n'
    '            text_parts.append(f"<thinking{sig_attr}>{thinking}</thinking>")',
    '        elif block_type == "thinking":\n'
    '            thinking = getattr(block, "thinking", None) or ""\n'
    '            text_parts.append(f"<think>{thinking}</think>")\n'
    '        elif block_type == "redacted_thinking":\n'
    '            pass',
    "responses: <thinking> -> <think> (responses format)")

# responses.py — second thinking block (convert__anthropic_message_to_openai_chat__response)
patch(responses_py,
    '        elif btype == "thinking":\n'
    '            thinking = getattr(block, "thinking", None)\n'
    '            signature = getattr(block, "signature", None)\n'
    '            if isinstance(thinking, str):\n'
    '                sig_attr = (\n'
    '                    f\' signature="{signature}"\'\n'
    '                    if isinstance(signature, str) and signature\n'
    '                    else ""\n'
    '                )\n'
    '                parts.append(f"<thinking{sig_attr}>{thinking}</thinking>")',
    '        elif btype == "thinking":\n'
    '            thinking = getattr(block, "thinking", None)\n'
    '            if isinstance(thinking, str):\n'
    '                parts.append(f"<think>{thinking}</think>")\n'
    '        elif btype == "redacted_thinking":\n'
    '            pass',
    "responses: <thinking> -> <think> (chat format)")

# streams.py — _anthropic_delta_to_text: return raw thinking text (tags emitted separately)
patch(streams_py,
    '    if block_type == "thinking":\n'
    '        thinking_text = delta.get("thinking")\n'
    '        if not isinstance(thinking_text, str) or not thinking_text:\n'
    '            return None\n'
    '        signature = block_meta.get("signature")\n'
    '        if isinstance(signature, str) and signature:\n'
    '            return f\'<thinking signature="{signature}">{thinking_text}</thinking>\'\n'
    '        return f"<thinking>{thinking_text}</thinking>"',
    '    if block_type == "thinking":\n'
    '        thinking_text = delta.get("thinking")\n'
    '        if isinstance(thinking_text, str) and thinking_text:\n'
    '            return thinking_text\n'
    '        return None',
    "streams: unwrap thinking text in _anthropic_delta_to_text")

# streams.py — add content_block_start handler to emit <think> in chat stream
patch(streams_py,
    '                if not message_started:\n'
    '                    continue\n'
    '\n'
    '                if event_type == "content_block_delta":',
    '                if not message_started:\n'
    '                    continue\n'
    '\n'
    '                if event_type == "content_block_start":\n'
    '                    content_block = (\n'
    '                        event_payload.get("content_block", {})\n'
    '                        if isinstance(event_payload, dict)\n'
    '                        else {}\n'
    '                    )\n'
    '                    if isinstance(content_block, dict) and content_block.get("type") == "thinking":\n'
    '                        yield openai_models.ChatCompletionChunk(\n'
    '                            id="chatcmpl-stream",\n'
    '                            object="chat.completion.chunk",\n'
    '                            created=0,\n'
    '                            model=model_id,\n'
    '                            choices=[\n'
    '                                openai_models.StreamingChoice(\n'
    '                                    index=0,\n'
    '                                    delta=openai_models.DeltaMessage(\n'
    '                                        role="assistant", content="<think>"\n'
    '                                    ),\n'
    '                                    finish_reason=None,\n'
    '                                )\n'
    '                            ],\n'
    '                        )\n'
    '                    continue\n'
    '\n'
    '                if event_type == "content_block_delta":',
    "streams: emit <think> on content_block_start for thinking")

# streams.py — content_block_stop: emit </think> for thinking blocks
patch(streams_py,
    '                if event_type == "content_block_stop":\n'
    '                    block_index = int(event_payload.get("index", 0))\n'
    '                    block_info = accumulator.get_block_info(block_index)\n'
    '                    if not block_info:\n'
    '                        continue\n'
    '                    _, block_meta = block_info\n'
    '                    if block_meta.get("type") != "tool_use":\n'
    '                        continue\n'
    '                    if block_index in emitted_tool_indices:\n'
    '                        continue\n'
    '                    tool_call = _build_openai_tool_call_chunk(accumulator, block_index)\n'
    '                    if tool_call is None:\n'
    '                        continue\n'
    '                    emitted_tool_indices.add(block_index)\n'
    '                    yield openai_models.ChatCompletionChunk(\n'
    '                        id="chatcmpl-stream",\n'
    '                        object="chat.completion.chunk",\n'
    '                        created=0,\n'
    '                        model=model_id,\n'
    '                        choices=[\n'
    '                            openai_models.StreamingChoice(\n'
    '                                index=0,\n'
    '                                delta=openai_models.DeltaMessage(\n'
    '                                    role="assistant", tool_calls=[tool_call]\n'
    '                                ),\n'
    '                                finish_reason=None,\n'
    '                            )\n'
    '                        ],\n'
    '                    )\n'
    '                    continue',
    '                if event_type == "content_block_stop":\n'
    '                    block_index = int(event_payload.get("index", 0))\n'
    '                    block_info = accumulator.get_block_info(block_index)\n'
    '                    if not block_info:\n'
    '                        continue\n'
    '                    _, block_meta = block_info\n'
    '                    block_type = block_meta.get("type")\n'
    '                    if block_type == "thinking":\n'
    '                        yield openai_models.ChatCompletionChunk(\n'
    '                            id="chatcmpl-stream",\n'
    '                            object="chat.completion.chunk",\n'
    '                            created=0,\n'
    '                            model=model_id,\n'
    '                            choices=[\n'
    '                                openai_models.StreamingChoice(\n'
    '                                    index=0,\n'
    '                                    delta=openai_models.DeltaMessage(\n'
    '                                        role="assistant", content="</think>"\n'
    '                                    ),\n'
    '                                    finish_reason=None,\n'
    '                                )\n'
    '                            ],\n'
    '                        )\n'
    '                        continue\n'
    '                    if block_type != "tool_use":\n'
    '                        continue\n'
    '                    if block_index in emitted_tool_indices:\n'
    '                        continue\n'
    '                    tool_call = _build_openai_tool_call_chunk(accumulator, block_index)\n'
    '                    if tool_call is None:\n'
    '                        continue\n'
    '                    emitted_tool_indices.add(block_index)\n'
    '                    yield openai_models.ChatCompletionChunk(\n'
    '                        id="chatcmpl-stream",\n'
    '                        object="chat.completion.chunk",\n'
    '                        created=0,\n'
    '                        model=model_id,\n'
    '                        choices=[\n'
    '                            openai_models.StreamingChoice(\n'
    '                                index=0,\n'
    '                                delta=openai_models.DeltaMessage(\n'
    '                                    role="assistant", tool_calls=[tool_call]\n'
    '                                ),\n'
    '                                finish_reason=None,\n'
    '                            )\n'
    '                        ],\n'
    '                    )\n'
    '                    continue',
    "streams: emit </think> on content_block_stop for thinking")

# anthropic.py — add ServerToolUseBlock/ServerToolResultBlock/WebSearchToolResultBlock
patch(anthropic_py,
    '    data: str\n'
    '\n'
    '\n'
    'RequestContentBlock = Annotated[\n'
    '    TextBlock | ImageBlock | ToolUseBlock | ToolResultBlock, Field(discriminator="type")\n'
    ']\n'
    '\n'
    'ResponseContentBlock = Annotated[\n'
    '    TextBlock | ToolUseBlock | ThinkingBlock | RedactedThinkingBlock,\n'
    '    Field(discriminator="type"),\n'
    ']',
    '    data: str\n'
    '\n'
    '\n'
    'class ServerToolUseBlock(ContentBlockBase):\n'
    '    """Block for a server-side tool use (e.g. web_search)."""\n'
    '\n'
    '    type: Literal["server_tool_use"] = Field(default="server_tool_use", alias="type")\n'
    '    id: str\n'
    '    name: str\n'
    '    input: dict[str, Any]\n'
    '\n'
    '\n'
    'class ServerToolResultBlock(ContentBlockBase):\n'
    '    """Block for the result of a server-side tool use."""\n'
    '\n'
    '    type: Literal["server_tool_result"] = Field(\n'
    '        default="server_tool_result", alias="type"\n'
    '    )\n'
    '    tool_use_id: str\n'
    '    content: str | list[TextBlock | ImageBlock] = ""\n'
    '    is_error: bool = False\n'
    '\n'
    '\n'
    'class WebSearchToolResultBlock(ContentBlockBase):\n'
    '    """Block for a web search tool result."""\n'
    '\n'
    '    type: Literal["web_search_tool_result"] = Field(\n'
    '        default="web_search_tool_result", alias="type"\n'
    '    )\n'
    '    tool_use_id: str\n'
    '    content: Any\n'
    '\n'
    '\n'
    'RequestContentBlock = Annotated[\n'
    '    TextBlock | ImageBlock | ToolUseBlock | ToolResultBlock\n'
    '    | ThinkingBlock | RedactedThinkingBlock\n'
    '    | ServerToolUseBlock | ServerToolResultBlock\n'
    '    | WebSearchToolResultBlock,\n'
    '    Field(discriminator="type"),\n'
    ']\n'
    '\n'
    'ResponseContentBlock = Annotated[\n'
    '    TextBlock | ToolUseBlock | ThinkingBlock | RedactedThinkingBlock\n'
    '    | ServerToolUseBlock,\n'
    '    Field(discriminator="type"),\n'
    ']',
    "anthropic.py: add ServerToolUseBlock/ServerToolResultBlock/WebSearchToolResultBlock to content block unions")

# Increase streaming timeout to 30 minutes to allow extended thinking responses
utils_py = os.path.join(pkg, "config/utils.py")
patch(utils_py,
    'HTTP_STREAMING_TIMEOUT = 300.0  # 5 minutes for streaming requests',
    'HTTP_STREAMING_TIMEOUT = 1800.0  # 30 minutes for streaming requests (extended thinking)',
    "config/utils.py: increase HTTP_STREAMING_TIMEOUT to 30 minutes")
PYEOF
python3 /tmp/patch_ccproxy.py
rm /tmp/patch_ccproxy.py

# === Write access token and env vars ===
echo "$ACCESS_TOKEN" > "$HOME/.access"

for var in \
    "export PATH=/usr/local/go/bin:\$HOME/.local/bin:\$PATH" \
    "export GOPATH=$HOME/go"; do
    grep -qxF "$var" "$HOME/.bashrc" || echo "$var" >> "$HOME/.bashrc"
done

export GOPATH="$HOME/go"

# === Authenticate ccproxy (OAuth) ===
# Reads from ~/.claude/.credentials.json (Claude Code OAuth tokens) automatically.
if ! ccproxy auth status claude-api 2>/dev/null | grep -q "Authenticated"; then
    echo ">>> ccproxy not authenticated. Starting OAuth flow..."
    ccproxy auth login claude-api --no-browser &
    AUTH_PID=$!

    CALLBACK_URL="${CCPROXY_CALLBACK_URL:-}"
    if [ -z "$CALLBACK_URL" ] && [ -f "$HOME/.ccproxy_callback" ]; then
        CALLBACK_URL="$(head -n1 "$HOME/.ccproxy_callback")"
    fi
    if [ -z "$CALLBACK_URL" ]; then
        if [ -r /dev/tty ]; then
            printf '>>> Paste the callback URL from your browser and press Enter: ' > /dev/tty
            read -r CALLBACK_URL < /dev/tty || true
        else
            read -r CALLBACK_URL || true
        fi
    fi

    if [ -n "$CALLBACK_URL" ]; then
        curl -s "$CALLBACK_URL" > /dev/null || true
        wait "$AUTH_PID" 2>/dev/null || true
        echo ">>> ccproxy authenticated."
    else
        kill "$AUTH_PID" 2>/dev/null || true
        echo "ERROR: ccproxy OAuth needs a callback URL. Set CCPROXY_CALLBACK_URL," >&2
        echo "       write it to ~/.ccproxy_callback, or run the script interactively." >&2
        exit 1
    fi
fi

# === Write ccproxy config (claude_api only, port 8585) ===
mkdir -p "$(dirname "$CCPROXY_CONFIG")"
ccproxy config init --output-dir "$(dirname "$CCPROXY_CONFIG")" --force 2>/dev/null || true
sed -i 's/^# enabled_plugins =.*/enabled_plugins = ["claude_api", "oauth_claude"]/' "$CCPROXY_CONFIG"
sed -i 's/^# \[server\]/[server]/'                    "$CCPROXY_CONFIG"
sed -i 's/^# host = "127\.0\.0\.1"/host = "127.0.0.1"/' "$CCPROXY_CONFIG"
sed -i "s/^# port = 8000/port = $CCPROXY_PORT/"       "$CCPROXY_CONFIG"

# System prompt injection mode. OAuth/subscription credentials REQUIRE every
# request to carry the Claude Code identity ("You are Claude Code, ...") or
# Anthropic rejects it with a generic 429 rate_limit_error. So "none" is wrong —
# it breaks auth. "full" prepends Anthropic's entire Claude Code system prompt,
# which overrides shelley's tool instructions and returns stop_reason "end_turn"
# instead of "tool_use". "minimal" prepends only the first (identity) block,
# satisfying the OAuth gate while preserving shelley's own system prompt + tools.
cat >> "$CCPROXY_CONFIG" << 'EOF'

[plugins.claude_api]
system_prompt_injection_mode = "minimal"
EOF

# === Start ccproxy ===
pkill -f "ccproxy serve" 2>/dev/null || true
sleep 1

nohup ccproxy serve --config "$CCPROXY_CONFIG" > /tmp/ccproxy.log 2>&1 &
CCPROXY_PID=$!
echo ">>> ccproxy starting (PID $CCPROXY_PID)..."

for i in $(seq 1 30); do
    if ss -tlnp 2>/dev/null | grep -q ":$CCPROXY_PORT"; then
        break
    fi
    sleep 1
done

if ! ss -tlnp 2>/dev/null | grep -q ":$CCPROXY_PORT"; then
    echo "ERROR: ccproxy failed to start on port $CCPROXY_PORT. Check /tmp/ccproxy.log" >&2
    exit 1
fi
echo ">>> ccproxy running on http://127.0.0.1:$CCPROXY_PORT"

# === Clone Shelley (skip if already present) ===
if [ ! -d "$SHELLEY_DIR" ]; then
    git clone -q https://github.com/boldsoftware/shelley.git "$SHELLEY_DIR"
fi

# Patch Shelley to route Claude API calls through ccproxy
sed -i "s|DefaultURL\s*=\s*\"[^\"]*\"|DefaultURL   = \"http://localhost:$CCPROXY_PORT/claude/v1/messages\"|" \
    "$SHELLEY_DIR/llm/ant/ant.go"

# Patch Shelley loop/loop.go: give each retry attempt its own fresh 30-minute
# context so network timeouts are retried rather than immediately re-failing
# on a context that is already cancelled.
cat > /tmp/patch_shelley_loop.py << 'PYEOF'
import sys, os

path = os.path.join(sys.argv[1], "loop", "loop.go")
with open(path) as f:
    src = f.read()

old = (
    '\t\t// Add a timeout for the LLM request to prevent indefinite hangs\n'
    '\t\tllmCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)\n'
    '\n'
    '\t\t// Retry LLM requests that fail with retryable errors (EOF, connection reset).\n'
    '\t\t// Provider-internal retries own user-visible retry warnings; this outer retry\n'
    '\t\t// catches transport failures that escape the provider without adding noise.\n'
    '\t\tconst maxRetries = 2\n'
    '\t\tvar resp *llm.Response\n'
    '\t\tvar err error\n'
    '\tretryLoop:\n'
    '\t\tfor attempt := 1; attempt <= maxRetries; attempt++ {\n'
    '\t\t\tresp, err = llmService.Do(llmCtx, req)\n'
    '\t\t\tif err == nil {\n'
    '\t\t\t\tbreak\n'
    '\t\t\t}\n'
    '\t\t\tif !isRetryableError(err) || attempt == maxRetries {\n'
    '\t\t\t\tbreak\n'
    '\t\t\t}\n'
    '\t\t\tsleep := time.Second * time.Duration(attempt)\n'
    '\t\t\tl.logger.Warn("LLM request failed with retryable error, retrying",\n'
    '\t\t\t\t"error", err,\n'
    '\t\t\t\t"attempt", attempt,\n'
    '\t\t\t\t"max_retries", maxRetries)\n'
    '\t\t\tselect {\n'
    '\t\t\tcase <-time.After(sleep):\n'
    '\t\t\tcase <-llmCtx.Done():\n'
    '\t\t\t\terr = llmCtx.Err()\n'
    '\t\t\t\tbreak retryLoop\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '\t\tcancel()'
)

new = (
    '\t\t// Retry LLM requests that fail with retryable errors (EOF, connection reset,\n'
    '\t\t// timeout). Each attempt gets its own fresh 30-minute context so a timed-out\n'
    '\t\t// attempt can still be retried rather than the shared context being dead.\n'
    '\t\tconst (\n'
    '\t\t\tmaxRetries = 2\n'
    '\t\t\tllmTimeout = 30 * time.Minute\n'
    '\t\t)\n'
    '\t\tvar resp *llm.Response\n'
    '\t\tvar err error\n'
    '\t\tfor attempt := 1; attempt <= maxRetries; attempt++ {\n'
    '\t\t\tllmCtx, cancel := context.WithTimeout(ctx, llmTimeout)\n'
    '\t\t\tresp, err = llmService.Do(llmCtx, req)\n'
    '\t\t\tcancel()\n'
    '\t\t\tif err == nil {\n'
    '\t\t\t\tbreak\n'
    '\t\t\t}\n'
    '\t\t\tif !isRetryableError(err) || attempt == maxRetries {\n'
    '\t\t\t\tbreak\n'
    '\t\t\t}\n'
    '\t\t\tsleep := time.Second * time.Duration(attempt)\n'
    '\t\t\tl.logger.Warn("LLM request failed with retryable error, retrying",\n'
    '\t\t\t\t"error", err,\n'
    '\t\t\t\t"attempt", attempt,\n'
    '\t\t\t\t"max_retries", maxRetries)\n'
    '\t\t\tselect {\n'
    '\t\t\tcase <-time.After(sleep):\n'
    '\t\t\tcase <-ctx.Done():\n'
    '\t\t\t\terr = ctx.Err()\n'
    '\t\t\t\tbreak\n'
    '\t\t\t}\n'
    '\t\t}'
)

if old not in src:
    print("SKIP (already applied or not found): loop.go per-attempt timeout", file=sys.stderr)
else:
    with open(path, "w") as f:
        f.write(src.replace(old, new, 1))
    print("Patched: loop.go per-attempt timeout")
PYEOF
python3 /tmp/patch_shelley_loop.py "$SHELLEY_DIR"
rm /tmp/patch_shelley_loop.py

# === Build Shelley ===
cd "$SHELLEY_DIR/ui"
pnpm --silent install --frozen-lockfile
pnpm --silent run build

cd "$SHELLEY_DIR"
make templates
go build -o bin/shelley ./cmd/shelley

# Wrapper: sets ANTHROPIC_API_KEY so shelley's model discovery activates the
# Anthropic catalog. Any non-empty value works — requests still route through
# ccproxy (OAuth) so the key value is never sent upstream.
cat > "$SHELLEY_DIR/bin/shelley-serve" << 'WEOF'
#!/bin/bash
export ANTHROPIC_API_KEY=dummy
exec "$(dirname "$0")/shelley" "$@"
WEOF
chmod +x "$SHELLEY_DIR/bin/shelley-serve"
echo ">>> Shelley built successfully"

# === Start Shelley ===
pkill -f "shelley serve" 2>/dev/null || true
sleep 1

cd "$HOME"
nohup "$SHELLEY_DIR/bin/shelley-serve" serve --port "$SHELLEY_PORT" \
    > /tmp/shelley.log 2>&1 &
echo ">>> Shelley starting..."

for i in $(seq 1 30); do
    if ss -tlnp 2>/dev/null | grep -q ":$SHELLEY_PORT"; then
        break
    fi
    sleep 1
done

if ! ss -tlnp 2>/dev/null | grep -q ":$SHELLEY_PORT"; then
    echo "ERROR: Shelley failed to start. Check /tmp/shelley.log" >&2
    exit 1
fi
echo ">>> Shelley running on http://127.0.0.1:$SHELLEY_PORT"

# === Register ccproxy and Shelley to start at boot ===
STARTUP_SCRIPT="$HOME/.start-services.sh"
cat > "$STARTUP_SCRIPT" << SEOF
#!/bin/bash
export HOME=$HOME
export PATH="$HOME/.local/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin"
export ANTHROPIC_API_KEY=dummy

echo "=== start-services \$(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> /tmp/start-services.log

pkill -f "ccproxy serve" 2>/dev/null || true
sleep 1
nohup ccproxy serve --config "$CCPROXY_CONFIG" >> /tmp/ccproxy.log 2>&1 &

pkill -f "shelley serve" 2>/dev/null || true
sleep 1
cd $HOME && nohup "$SHELLEY_DIR/bin/shelley-serve" serve --port $SHELLEY_PORT >> /tmp/shelley.log 2>&1 &

printf 'ccproxy : http://127.0.0.1:$CCPROXY_PORT\nshelley : http://127.0.0.1:$SHELLEY_PORT\n' > $HOME/urls.txt
SEOF
chmod +x "$STARTUP_SCRIPT"

(crontab -l 2>/dev/null | grep -vF ".start-services.sh" || true; echo "@reboot $STARTUP_SCRIPT") | crontab -
echo ">>> Services registered to start at boot"

# === Show Shelley URL on terminal login ===
sed -i '/# Show Shelley URL/{ N; d }' "$HOME/.bashrc"
cat >> "$HOME/.bashrc" << 'BASHRC'

# Show Shelley URL on every interactive terminal login.
echo "  Shelley : http://127.0.0.1:9000"
BASHRC

# === Save and print URLs ===
cat > "$HOME/urls.txt" << URLEOF
ccproxy : http://127.0.0.1:$CCPROXY_PORT
shelley : http://127.0.0.1:$SHELLEY_PORT
URLEOF

echo ""
echo "=========================================="
echo "  ccproxy  : http://127.0.0.1:$CCPROXY_PORT"
echo "  shelley  : http://127.0.0.1:$SHELLEY_PORT"
echo "  urls file: $HOME/urls.txt"
echo "  logs     : /tmp/ccproxy.log /tmp/shelley.log"
echo "=========================================="
