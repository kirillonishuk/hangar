#!/bin/bash
# Fixture world for README screenshots/video: neutral names, /tmp only, fake agents and ssh (never a real claude/codex).
# TYPESCRIPT_DIR: any local node_modules/typescript (tsserver for the editor's hover/definition); optional.
set -euo pipefail
source "$(dirname "$0")/common.sh"
HANGAR_BIN=$BIN/hangar
rm -rf "$R"
mkdir -p "$R"/{state,zdot,bin,claude/projects,codex/sessions,work,snaps,frames,home,sshd,origin}
export GIT_AUTHOR_NAME="Ada Lovelace" GIT_AUTHOR_EMAIL="ada@example.com"
export GIT_COMMITTER_NAME="Ada Lovelace" GIT_COMMITTER_EMAIL="ada@example.com"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# Integrations are "on" (no first-run sheet) but MCP is off: MCP registration would go through the agent CLIs.
cat > "$R/config.toml" <<EOF
language = "${MEDIA_LANG:-en}"
theme = "navy"
notifications = false
keep_awake = true
dock_badge = false
check_updates = false
claude_integration = true
claude_mcp = false
codex_integration = true
codex_mcp = false
integration_hosts_skipped = ["devbox"]

[agents]
claude = "$R/bin/claude"
codex = "$R/bin/codex"
EOF

# Neutral prompt; ZDOTDIR is inherited through login -p and Ghostty's zsh integration.
cat > "$R/zdot/.zshenv" <<EOF
export HOME=$R/home
export PATH=$R/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
EOF
cat > "$R/zdot/.zshrc" <<'EOF'
PROMPT='%F{75}%1~%f %F{245}❯%f '
RPROMPT=''
unsetopt PROMPT_SP
setopt PROMPT_SUBST
HISTFILE=/dev/null
printf '\e[H\e[2J\e[3J'
EOF
cp "$R/zdot/.zshrc" "$R/home/.zshrc"; cp "$R/zdot/.zshenv" "$R/home/.zshenv"

# Fake Claude Code: a scripted transcript per prompt, hook events (working → done / waiting / error) and Hangar's
# own status line (`hangar statusline`, which also reports the usage limits to the app).
cat > "$R/bin/claude" <<'EOF'
#!/bin/bash
H=__HANGAR_BIN__
SID=; P=
while [ $# -gt 0 ]; do
  case "$1" in
    --version) echo "2.1.3 (Claude Code)"; exit 0 ;;
    mcp) exit 0 ;;
    --settings) shift 2 ;;
    --session-id|--resume) SID=$2; shift 2 ;;
    --) shift ;;
    *) P=$1; shift ;;
  esac
done
P="${P# }"; SID=${SID:-$(uuidgen | tr A-Z a-z)}
# Chats started without a prompt (ptask, wtask) get theirs from the folder.
[ -z "$P" ] && [ "$(basename "$PWD")" = search-bar ] && P="Build a search bar with keyboard navigation"
if [ -z "$P" ] && [ "$(basename "$PWD")" = api ]; then
  case "$PWD" in */sshd/*) P="Add created_at to orders and backfill it" ;; *) P="Add a /healthz endpoint for the load balancer" ;; esac
fi
# On the fake server the hooks go through hangar-remote, as a real Claude's would there.
ev() {
  local j="{\"session_id\":\"$SID\"${2:+,$2}}"
  case "$PWD" in
    */sshd/*) printf %s "$j" | "$HOME/.hangar/bin/hangar-remote" event "$1" >/dev/null 2>&1 ;;
    *) "$H" event "$1" "$j" >/dev/null 2>&1 ;;
  esac
  true
}
o=$'\e[38;5;209m'; d=$'\e[2m'; g=$'\e[32m'; r=$'\e[31m'; b=$'\e[1m'; n=$'\e[0m'; c=$'\e[36m'; y=$'\e[33m'
W=58
line() { printf '%s%s%s\n' "$1" "$(printf '─%.0s' $(seq 1 $W))" "$n"; }
box() { printf '%s╭' "$1"; printf '─%.0s' $(seq 1 $W); printf '╮%s\n' "$n"; }
boxend() { printf '%s╰' "$1"; printf '─%.0s' $(seq 1 $W); printf '╯%s\n' "$n"; }
row() { local t="$2" v="$3"; printf '%s│%s %s%*s%s│%s\n' "$1" "$n" "$t" $((W - 1 - ${#v})) "" "$1" "$n"; }
ev session-start '"source":"startup"'
printf '\e[H\e[2J\e[3J'
box "$o"
row "$o" "${o}✻${n} Welcome to ${b}Claude Code${n}" "✻ Welcome to Claude Code"
row "$o" "" ""
row "$o" "  ${d}/help for help, /status for your current setup${n}" "  /help for help, /status for your current setup"
row "$o" "" ""
CWD=$(printf %s "$PWD" | sed -E 's#^(/private)?/tmp/hg-media/(sshd/home/)?#~/#')
row "$o" "  ${d}cwd: $CWD${n}" "  cwd: $CWD"
boxend "$o"
printf '\n'
status() { # status <ctx%> <5h%> <week%>
  local now; now=$(date +%s)
  printf '{"model":{"id":"claude-opus-4-6","display_name":"Opus 4.6"},"context_window":{"used_percentage":%s,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$1" "$2" $((now + 7920)) "$3" $((now + 345600)) | "$H" statusline 2>/dev/null
}
prompt_box() { line "$d"; printf '%s>%s %s\n' "$d" "$n" "${1:-}"; line "$d"; printf '  %s\n' "$(status "${2:-12}" 34 18)"; printf '  %s? for shortcuts%s' "$d" "$n"; }
if [ -z "$P" ]; then prompt_box; exec sleep 100000; fi
printf '%s>%s %s\n\n' "$d" "$n" "$P"
ev prompt "\"prompt\":\"$P\""
S=1
step() { printf '%s⏺%s %s\n' "$g" "$n" "$1"; [ -n "${2:-}" ] && printf '  %s⎿  %s%s\n' "$d" "$2" "$n"; printf '\n'; ev tool; sleep "$(echo "${3:-1.1} * $S" | bc)"; }
say() { printf '%s⏺%s %s\n\n' "$n" "$n" "$1"; sleep "${2:-0.8}"; }
case "$P" in
*discount*)
  step "Read(src/checkout/cart.ts)" "Read 27 lines"
  step "Search(pattern: \"subtotal\\(\", path: \"src\")" "Found 3 files"
  say "I'll add a ${b}DISCOUNTS${n} table and an ${c}applyDiscount()${n} helper, then a ${b}DiscountField${n} form."
  step "Update(src/checkout/cart.ts)" "Updated src/checkout/cart.ts with 9 additions and 2 removals" 1.4
  printf '     %s 3 +%s const DISCOUNTS: Record<string, number> = { WELCOME10: 0.1, SPRING25: 0.25 };%s\n' "$g" "" "$n"
  printf '     %s12 +%s export function applyDiscount(cart: Cart, code: string): Cart {%s\n' "$g" "" "$n"
  printf '     %s13 +%s   const rate = DISCOUNTS[code.trim().toUpperCase()];%s\n' "$g" "" "$n"
  printf '     %s21 -%s     existing.quantity += item.quantity;%s\n\n' "$r" "" "$n"
  step "Write(src/checkout/DiscountField.tsx)" "Wrote 14 lines to src/checkout/DiscountField.tsx" 1.4
  step "Bash(pnpm vitest run cart)" "✓ src/checkout/cart.test.ts (12 tests) 18ms" 1.4
  say "Done. Checkout accepts ${b}WELCOME10${n} and ${b}SPRING25${n}; unknown codes are ignored.
  ${c}addItem${n} no longer mutates the cart. All 12 tests pass." 0.3
  ev stop '"last_assistant_message":"Done. Checkout accepts discount codes; tests pass."'
  prompt_box "" 38 ;;
*search*)
  S=6
  step "Read(src/ui/Button.tsx)" "Read 3 lines" 0.5
  step "Search(pattern: \"onKeyDown\", path: \"src\")" "Found 0 files" 0.5
  say "There's no keyboard handling yet. I'll build ${b}SearchBar${n}: ↑/↓ to move, Enter to open." 1
  step "Write(src/ui/SearchBar.tsx)" "Wrote 46 lines to src/ui/SearchBar.tsx" 0.6
  printf '%s✻%s Writing tests… %s(esc to interrupt)%s\n' "$o" "$n" "$d" "$n"
  exec sleep 100000 ;;
*e2e*)
  step "Bash(pnpm playwright test checkout)" "Running 8 tests using 4 workers" 1.2
  printf '%s  ⎿  API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}%s\n\n' "$r" "$n"
  ev stop-failure '"error":"server_error","message":"API Error: 529 Overloaded"'
  prompt_box "" 21 ;;
*healthz*)
  step "Read(cmd/server/main.go)" "Read 5 lines"
  say "I'll add a ${b}/healthz${n} handler that pings the database."
  step "Write(internal/health/health.go)" "Wrote 24 lines to internal/health/health.go" 1.3
  step "Update(cmd/server/main.go)" "Updated cmd/server/main.go with 2 additions" 1.3
  step "Bash(go test ./...)" "ok  example.com/api/internal/health  0.41s" 1.3
  say "Done. GET /healthz returns 200 when the database is reachable, 503 otherwise." 0.3
  ev stop '"last_assistant_message":"Done. GET /healthz is ready."'
  prompt_box "" 17 ;;
*)
  S=8
  step "Read(internal/orders/order.go)" "Read 6 lines" 0.4
  say "I'll add a ${b}created_at${n} column and backfill it in batches of 1,000." 0.6
  step "Write(migrations/0007_orders_created_at.sql)" "Wrote 11 lines" 0.5
  printf '%s✻%s Running migration on staging… %s(esc to interrupt)%s\n' "$o" "$n" "$d" "$n"
  exec sleep 100000 ;;
esac
exec sleep 100000
EOF
sed -i '' "s|__HANGAR_BIN__|$HANGAR_BIN|" "$R/bin/claude"

# Fake Codex CLI: proposes a change and stops at a command approval (bell → the chat waits).
cat > "$R/bin/codex" <<'EOF'
#!/bin/bash
[ "${1:-}" = --version ] && { echo "codex-cli 0.50.0"; exit 0; }
[ "${1:-}" = mcp ] && exit 0
P=; while [ $# -gt 0 ]; do case "$1" in resume) shift 2 ;; -*) shift ;; *) P=$1; shift ;; esac; done
P="${P# }"; P=${P:-Fix rounding of cart totals in EUR}
d=$'\e[2m'; b=$'\e[1m'; g=$'\e[32m'; r=$'\e[31m'; c=$'\e[36m'; n=$'\e[0m'
printf '\e[H\e[2J\e[3J'
CWD=$(printf %s "$PWD" | sed -E 's#^(/private)?/tmp/hg-media/(sshd/home/)?#~/#')
bar=$(printf '─%.0s' $(seq 1 62))
r() { printf '│ %s%*s│\n' "$1" $((61 - ${#2})) ""; }  # r <styled> <plain>
printf '╭%s╮\n' "$bar"
r "$d>_$n ${b}OpenAI Codex$n (v0.50.0)" ">_ OpenAI Codex (v0.50.0)"
r "" ""
r "${d}model:$n     gpt-5-codex high   $c/model to change$n" "model:     gpt-5-codex high   /model to change"
r "${d}directory:$n $CWD" "directory: $CWD"
printf '╰%s╯\n\n' "$bar"
printf '%s›%s %s\n\n' "$d" "$n" "$P"; sleep 1.2
printf '• Totals are summed in floating point and rounded only when formatted, so\n  %s0.1 + 0.2%s lands on %s0.30000000000000004%s before EUR formatting.\n\n' "$c" "$n" "$c" "$n"; sleep 1
printf '• %sExplored%s\n  └ Read cart.ts, types.ts\n    Search toFixed in src\n\n' "$b" "$n"; sleep 1
printf '• %sEdited%s src/checkout/cart.ts (%s+4%s %s-1%s)\n' "$b" "$n" "$g" "$n" "$r" "$n"
printf '    %s 6 -  return cart.items.reduce((sum, item) => sum + item.price * item.quantity, 0);%s\n' "$r" "$n"
printf '    %s 6 +  const cents = cart.items.reduce((sum, i) => sum + Math.round(i.price * 100) * i.quantity, 0);%s\n' "$g" "$n"
printf '    %s 7 +  return cents / 100;%s\n\n' "$g" "$n"; sleep 1
printf '  Would you like to run the following command?\n\n'
printf '  %s$ pnpm vitest run cart --reporter=dot%s\n\n' "$b" "$n"
printf '%s›%s 1. Yes, proceed\n  2. Yes, and don'"'"'t ask again for this command\n  3. No, and tell Codex what to do differently %sesc%s\n\n' "$c" "$n" "$d" "$n"
printf '  %sPress enter to confirm or esc to cancel%s\a' "$d" "$n"
exec sleep 100000
EOF
chmod +x "$R/bin/claude" "$R/bin/codex"

# --- acme-web: a small TypeScript app with history, local and remote branches and uncommitted changes.
W="$R/work/acme-web"
mkdir -p "$W/src/checkout" "$W/src/ui" "$W/node_modules"
cd "$W"
git init -q -b main
cat > package.json <<'EOF'
{
  "name": "acme-web",
  "version": "1.4.0",
  "private": true,
  "packageManager": "pnpm@9.12.0",
  "scripts": { "dev": "vite", "test": "vitest" },
  "devDependencies": { "typescript": "^5.8.3", "vitest": "^3.2.0" }
}
EOF
printf 'lockfileVersion: "9.0"\n' > pnpm-lock.yaml
cat > tsconfig.json <<'EOF'
{
  "compilerOptions": { "target": "ES2022", "module": "ESNext", "moduleResolution": "Bundler", "strict": true, "jsx": "preserve" },
  "include": ["src"]
}
EOF
printf 'node_modules/\ndist/\n.env*\n' > .gitignore
mkdir -p "$W/src/types"
cat > "$W/src/types/shims.d.ts" <<'EOF'
declare module "react" {
  export function useState<T>(initial: T): [T, (value: T) => void];
}
declare namespace JSX {
  interface IntrinsicElements { [name: string]: any }
}
EOF
cat > README.md <<'EOF'
# acme-web

Storefront for ACME Corp.
EOF
cat > src/checkout/types.ts <<'EOF'
export interface LineItem {
  sku: string;
  title: string;
  price: number;
  quantity: number;
}

export interface Cart {
  items: LineItem[];
  currency: "USD" | "EUR";
  discount?: number;
}
EOF
cat > src/checkout/cart.ts <<'EOF'
import type { Cart, LineItem } from "./types";

/** Sum of all line items before discounts. */
export function subtotal(cart: Cart): number {
  return cart.items.reduce((sum, item) => sum + item.price * item.quantity, 0);
}

export function addItem(cart: Cart, item: LineItem): Cart {
  const existing = cart.items.find((i) => i.sku === item.sku);
  if (existing) {
    existing.quantity += item.quantity;
    return { ...cart };
  }
  return { ...cart, items: [...cart.items, item] };
}

export function formatPrice(amount: number, currency: Cart["currency"]): string {
  return new Intl.NumberFormat("en-US", { style: "currency", currency }).format(amount);
}
EOF
cat > src/checkout/Summary.tsx <<'EOF'
import { subtotal, formatPrice } from "./cart";
import type { Cart } from "./types";

export function Summary({ cart }: { cart: Cart }) {
  const total = subtotal(cart);
  // TODO: show the discount line once codes are supported
  return (
    <section className="summary">
      <h2>Order summary</h2>
      <p>{cart.items.length} items</p>
      <strong>{formatPrice(total, cart.currency)}</strong>
    </section>
  );
}
EOF
cat > src/ui/Button.tsx <<'EOF'
export function Button({ label, onClick }: { label: string; onClick: () => void }) {
  return <button className="btn" onClick={onClick}>{label}</button>;
}
EOF
cat > src/index.ts <<'EOF'
export { Summary } from "./checkout/Summary";
export { addItem, subtotal } from "./checkout/cart";
EOF
commit() { git add -A; GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git commit -qm "$2" ${3:-}; }
commit "2026-10-20T10:12:00" "Initial storefront skeleton"
echo 'export const FREE_SHIPPING_FROM = 50;' > src/checkout/shipping.ts
commit "2026-10-21T15:40:00" "feat(checkout): free shipping threshold"
sed -i '' 's/Storefront for ACME Corp./Storefront for ACME Corp. Run `pnpm dev`./' README.md
commit "2026-10-22T09:05:00" "docs: how to run locally"
printf 'export function Spinner() {\n  return <span className="spinner" aria-busy="true" />;\n}\n' > src/ui/Spinner.tsx
GIT_AUTHOR_NAME="Grace Hopper" GIT_AUTHOR_EMAIL=grace@example.com commit "2026-10-23T11:30:00" "feat(ui): loading spinner"
# A remote with branches of its own (the branch switcher's «Remote» group), then local-only branches.
git init -q --bare "$R/origin/acme-web.git"
git remote add origin "$R/origin/acme-web.git"
git push -q origin main
git switch -q -c release/1.4; echo '1.4.1' > VERSION; commit "2026-10-24T08:00:00" "chore: release 1.4.1"; git push -q origin release/1.4
git switch -q main; git switch -q -c feat/wishlist; echo 'export const WISHLIST_LIMIT = 50;' > src/checkout/wishlist.ts
GIT_AUTHOR_NAME="Grace Hopper" GIT_AUTHOR_EMAIL=grace@example.com commit "2026-10-25T14:20:00" "feat: wishlist limit"; git push -q origin feat/wishlist
git switch -q main; git branch -q -D release/1.4 feat/wishlist
git fetch -q origin
git branch feat/search-bar
git branch fix/currency-rounding
git branch feat/discount-codes
git branch -q -u origin/main main
# Separate copies (worktrees) beside the project, as Hangar makes them (#121).
git worktree add -q "$R/work/acme-web.worktrees/search-bar" feat/search-bar
git worktree add -q "$R/work/acme-web.worktrees/currency-rounding" fix/currency-rounding
# Uncommitted work in progress (Changes tab / diff).
cat > src/checkout/cart.ts <<'EOF'
import type { Cart, LineItem } from "./types";

const DISCOUNTS: Record<string, number> = { WELCOME10: 0.1, SPRING25: 0.25 };

/** Sum of all line items before discounts. */
export function subtotal(cart: Cart): number {
  return cart.items.reduce((sum, item) => sum + item.price * item.quantity, 0);
}

/** Applies a discount code; unknown codes leave the cart unchanged. */
export function applyDiscount(cart: Cart, code: string): Cart {
  const rate = DISCOUNTS[code.trim().toUpperCase()];
  if (rate === undefined) return cart;
  return { ...cart, discount: Math.round(subtotal(cart) * rate * 100) / 100 };
}

export function addItem(cart: Cart, item: LineItem): Cart {
  const existing = cart.items.find((i) => i.sku === item.sku);
  if (existing) {
    return { ...cart, items: cart.items.map((i) => (i.sku === item.sku ? { ...i, quantity: i.quantity + item.quantity } : i)) };
  }
  return { ...cart, items: [...cart.items, item] };
}

export function formatPrice(amount: number, currency: Cart["currency"]): string {
  return new Intl.NumberFormat("en-US", { style: "currency", currency }).format(amount);
}
EOF
cat > src/checkout/DiscountField.tsx <<'EOF'
import { useState } from "react";
import { applyDiscount } from "./cart";
import type { Cart } from "./types";

export function DiscountField({ cart, onApply }: { cart: Cart; onApply: (c: Cart) => void }) {
  const [code, setCode] = useState("");
  return (
    <form onSubmit={(e) => { e.preventDefault(); onApply(applyDiscount(cart, code)); }}>
      <input value={code} onChange={(e) => setCode(e.target.value)} placeholder="Discount code" />
      <button type="submit">Apply</button>
    </form>
  );
}
EOF
sed -i '' 's|  // TODO: show the discount line once codes are supported|  const discount = cart.discount ?? 0;|; s|<strong>{formatPrice(total, cart.currency)}</strong>|{discount > 0 \&\& <p>Discount −{formatPrice(discount, cart.currency)}</p>}\n      <strong>{formatPrice(total - discount, cart.currency)}</strong>|' src/checkout/Summary.tsx
[ -n "${TYPESCRIPT_DIR:-}" ] && cp -R "$TYPESCRIPT_DIR" "$W/node_modules/typescript"

# --- api: a second project (Go service).
A="$R/work/api"
mkdir -p "$A/cmd/server" "$A/internal/orders"
cd "$A"; git init -q -b main
printf 'module example.com/api\n\ngo 1.23\n' > go.mod
printf 'package main\n\nfunc main() {\n\tserve(":8080")\n}\n' > cmd/server/main.go
printf 'package orders\n\ntype Order struct {\n\tID    string\n\tTotal int64\n}\n' > internal/orders/order.go
commit "2026-10-19T12:00:00" "Initial API service"
printf 'package orders\n\nfunc List(limit int) []Order { return nil }\n' > internal/orders/list.go
commit "2026-10-21T10:30:00" "feat(orders): list endpoint"
GIT_AUTHOR_NAME="Grace Hopper" GIT_AUTHOR_EMAIL=grace@example.com commit "2026-10-22T16:05:00" "chore: go 1.23" --allow-empty
printf 'FROM golang:1.23-alpine\nWORKDIR /src\nCOPY . .\nRUN go build ./cmd/server\n' > Dockerfile
commit "2026-10-24T09:40:00" "build: Dockerfile"
printf 'package orders\n\nconst MaxPage = 100\n' > internal/orders/page.go
GIT_AUTHOR_NAME="Grace Hopper" GIT_AUTHOR_EMAIL=grace@example.com commit "2026-10-28T13:15:00" "feat(orders): cap page size at 100"

# --- Past conversations for History (fixture ~/.claude/projects and ~/.codex/sessions).
enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
conv() { # dir id title date branch msgs
  local d="$R/claude/projects/$(enc "$1")"; mkdir -p "$d"; local f="$d/$2.jsonl"; : > "$f"
  local i=0
  while [ $i -lt "$6" ]; do
    local t; if [ $((i % 2)) = 0 ]; then t=user; else t=assistant; fi
    local text="$3"; [ $i -gt 0 ] && text="ok"
    printf '{"type":"%s","cwd":"%s","gitBranch":"%s","timestamp":"%sT%02d:%02d:00.000Z","message":{"role":"%s","content":"%s"}}\n' \
      "$t" "$1" "$5" "$4" $((9 + i / 60)) $((i % 60)) "$t" "$text" >> "$f"
    i=$((i + 1))
  done
}
conv "$W" 6b1f0c2e-1a2b-4c3d-8e9f-000000000002 "Why does the cart total round 0.1 + 0.2 wrong?" 2026-10-29 fix/currency-rounding 12
conv "$W" 6b1f0c2e-1a2b-4c3d-8e9f-000000000003 "Sketch the search bar API before writing it" 2026-10-28 feat/search-bar 40
conv "$W" 6b1f0c2e-1a2b-4c3d-8e9f-000000000004 "Write tests for formatPrice in EUR and USD" 2026-10-27 main 16
conv "$W" 6b1f0c2e-1a2b-4c3d-8e9f-000000000005 "Refactor Summary into smaller components" 2026-10-26 main 8
conv "$A" 6b1f0c2e-1a2b-4c3d-8e9f-000000000006 "Add pagination to GET /orders" 2026-10-28 main 22
cx() { # id title date branch
  local d="$R/codex/sessions/2026/10/$(echo $3 | cut -c9-10)"; mkdir -p "$d"; local f="$d/rollout-$3T10-00-00-$1.jsonl"
  printf '{"timestamp":"%sT10:00:00.000Z","type":"session_meta","payload":{"id":"%s","cwd":"%s","git":{"branch":"%s"}}}\n' "$3" "$1" "$W" "$4" > "$f"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf '{"timestamp":"%sT10:%02d:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"%s"}}\n{"timestamp":"%sT10:%02d:30.000Z","type":"event_msg","payload":{"type":"agent_message","message":"ok"}}\n' "$3" $i "$2" "$3" $i >> "$f"
  done
}
cx 7c2a1d3e-2b3c-4d5e-9f00-000000000011 "Review the checkout flow for accessibility issues" 2026-10-29 main
cx 7c2a1d3e-2b3c-4d5e-9f00-000000000012 "Migrate the cart store to a reducer" 2026-10-27 main
mkdir -p "$R/claude"; echo '{}' > "$R/claude/settings.json"; mkdir -p "$R/codex"; : > "$R/codex/config.toml"

# --- Fake ssh "server" (devbox): runs commands locally with HOME=<sshd>/home; never touches the network.
mkdir -p "$R/sshd/home/srv"
cp -R "$A" "$R/sshd/home/srv/api"
cat > "$R/sshd/ssh" <<'EOF'
#!/bin/sh
D=${0%/*}
ctl=; fwd=; master=
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -O) ctl=$2; shift 2 ;;
    -R) fwd=$2; shift 2 ;;
    -o|-S|-L|-p|-l|-i|-F|-E|-e) shift 2 ;;
    -M) master=1; shift ;;
    -*) shift ;;
    *) break ;;
  esac
done
host=$1; shift
case "$ctl" in
  forward) ln -sf "${fwd#*:}" "${fwd%%:*}"; exit 0 ;;
  exit) kill "$(cat "$D/master.pid")" 2>/dev/null; exit 0 ;;
  ?*) exit 0 ;;
esac
[ -n "$master" ] && echo $$ > "$D/master.pid"
export HOME="$D/home" ZDOTDIR=/tmp/hg-media/zdot TMUX_TMPDIR=/tmp/hg-media/tmux; mkdir -p /tmp/hg-media/tmux
cd "$HOME" || exit 255
if [ $# -eq 0 ]; then exec sleep 100000; fi
exec sh -c "$*"
EOF
chmod +x "$R/sshd/ssh"
# hangar-remote already on the host (a DEBUG build can't upload it), from the script embedded in the app.
mkdir -p "$R/sshd/home/.hangar/bin"
awk '/^public let hangarRemoteScript = #"""/{f=1; next} /^"""#/{f=0} f' "$D/../../Sources/ControlServer/RemoteScript.swift" \
  | sed "s/\\\\#(hangarRemoteVersion)/$(sed -n 's/^public let hangarRemoteVersion = //p' "$D/../../Sources/ControlServer/RemoteScript.swift")/" \
  > "$R/sshd/home/.hangar/bin/hangar-remote"
chmod 700 "$R/sshd/home/.hangar/bin/hangar-remote"
# The shared zdot/.zshenv moves a login shell's HOME to $R/home: the host check looks there.
cp -R "$R/sshd/home/.hangar" "$R/home/"
printf 'Host devbox\n  HostName devbox.example.com\n  User dev\n' > "$R/sshd/config"
echo "fixture ready at $R"
