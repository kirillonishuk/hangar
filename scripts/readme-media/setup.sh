#!/bin/bash
# Fixture world for README screenshots/video: neutral names, /tmp only, fake agents and ssh.
# TYPESCRIPT_DIR: any local node_modules/typescript (tsserver for the editor's hover/definition); optional.
set -euo pipefail
source "$(dirname "$0")/common.sh"
HANGAR_BIN=$HANGAR_REPO/.build/debug/hangar
rm -rf "$R"
mkdir -p "$R"/{state,zdot,bin,claude/projects,codex/sessions,work,snaps,frames,home,sshd}
export GIT_AUTHOR_NAME="Ada Lovelace" GIT_AUTHOR_EMAIL="ada@example.com"
export GIT_COMMITTER_NAME="Ada Lovelace" GIT_COMMITTER_EMAIL="ada@example.com"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

cat > "$R/config.toml" <<EOF
language = "en"
notifications = true
limit_notifications = true
keep_awake = true
dock_badge = true

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

# Fake agents: Claude-like transcript + hook events so the sidebar shows working → waiting.
cat > "$R/bin/claude" <<EOF
#!/bin/bash
H=$HANGAR_BIN
[ "\${1:-}" = --version ] && { echo "2.1.0 (Claude Code)"; exit 0; }
SID=\$(uuidgen | tr A-Z a-z)
ev() { "\$H" event "\$1" "{\"session_id\":\"\$SID\"\${2:+,\$2}}" >/dev/null 2>&1 || true; }
o=\$'\e[38;5;209m'; d=\$'\e[2m'; g=\$'\e[32m'; r=\$'\e[31m'; b=\$'\e[1m'; n=\$'\e[0m'; c=\$'\e[36m'
ev session-start '"source":"startup"'
printf '\e[H\e[2J\e[3J'
printf '%s╭───────────────────────────────────────────────────╮%s\n' "\$o" "\$n"
printf '%s│%s %s✻%s Welcome to %sClaude Code%s%26s%s│%s\n' "\$o" "\$n" "\$o" "\$n" "\$b" "\$n" "" "\$o" "\$n"
printf '%s│%s   %scwd: %-43s%s%s│%s\n' "\$o" "\$n" "\$d" "\$(basename "\$PWD")" "\$n" "\$o" "\$n"
printf '%s╰───────────────────────────────────────────────────╯%s\n\n' "\$o" "\$n"
P="\${1:-Add a discount code field to the checkout}"
[ -z "\${1:-}" ] && [ "\$(basename "\$PWD")" = api ] && P="Add a /healthz endpoint for the load balancer"
S=1; case "\$P" in *search*) S=25;; esac
printf '%s>%s %s\n\n' "\$d" "\$n" "\$P"
sleep 0.8
ev prompt
step() { printf '%s⏺%s %s\n' "\$g" "\$n" "\$1"; [ -n "\${2:-}" ] && printf '  %s⎿  %s%s\n' "\$d" "\$2" "\$n"; ev tool; sleep \$(echo "\${3:-1.2} * \$S" | bc); }
if [ "\$(basename "\$PWD")" = api ]; then
step "Read(cmd/server/main.go)" "Read 5 lines"
step "I'll add a \${b}/healthz\${n} handler that checks the database connection."
step "Write(internal/health/health.go)" "Wrote 24 lines" 1.5
step "Update(cmd/server/main.go)" "Updated cmd/server/main.go with 2 additions" 1.5
step "Bash(go test ./...)" "ok  example.com/api/internal/health  0.41s" 1.5
printf '%s⏺%s Done. GET /healthz returns 200 when the database is reachable.\n\n' "\$g" "\$n"
else
step "Read(src/checkout/cart.ts)" "Read 64 lines"
step "Search(pattern: \"applyDiscount\", path: \"src\")" "Found 3 files"
step "I'll add a \${b}DiscountField\${n} component and validate codes in \${c}applyDiscount()\${n}."
step "Update(src/checkout/cart.ts)" "Updated src/checkout/cart.ts with 14 additions and 3 removals" 1.5
printf '     %s 41 +%s  export function applyDiscount(cart: Cart, code: string): Cart {%s\n' "\$g" "" "\$n"
printf '     %s 42 +%s    const rule = DISCOUNTS[code.trim().toUpperCase()];%s\n' "\$g" "" "\$n"
printf '     %s 43 -%s    return cart;%s\n\n' "\$r" "" "\$n"
step "Write(src/checkout/DiscountField.tsx)" "Wrote 38 lines" 1.5
step "Bash(npm test -- cart)" "PASS  src/checkout/cart.test.ts (12 tests)" 1.5
printf '%s⏺%s Done. The checkout now accepts discount codes; tests pass.\n\n' "\$g" "\$n"
fi
ev stop
printf '%s╭───────────────────────────────────────────────────╮%s\n' "\$d" "\$n"
printf '%s│%s >                                                 %s│%s\n' "\$d" "\$n" "\$d" "\$n"
printf '%s╰───────────────────────────────────────────────────╯%s\n' "\$d" "\$n"
printf '  %s? for shortcuts%s' "\$d" "\$n"
exec sleep 100000
EOF
sed -e "s/2.1.0 (Claude Code)/codex-cli 0.48.0/" -e "s/Claude Code/Codex      /" -e 's/38;5;209m/38;5;117m/' "$R/bin/claude" > "$R/bin/codex"
chmod +x "$R/bin/claude" "$R/bin/codex"

# --- acme-web: a small TypeScript app with history, branches and uncommitted changes.
W="$R/work/acme-web"
mkdir -p "$W/src/checkout" "$W/src/ui" "$W/node_modules"
cd "$W"
git init -q -b main
cat > package.json <<'EOF'
{
  "name": "acme-web",
  "version": "1.4.0",
  "private": true,
  "scripts": { "dev": "vite", "test": "vitest" },
  "devDependencies": { "typescript": "^5.8.3" }
}
EOF
cat > tsconfig.json <<'EOF'
{
  "compilerOptions": { "target": "ES2022", "module": "ESNext", "moduleResolution": "Bundler", "strict": true, "jsx": "preserve" },
  "include": ["src"]
}
EOF
printf 'node_modules/\ndist/\n' > .gitignore
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
git add -A; GIT_AUTHOR_DATE="2026-10-20T10:12:00" GIT_COMMITTER_DATE="2026-10-20T10:12:00" git commit -qm "Initial storefront skeleton"
echo 'export const FREE_SHIPPING_FROM = 50;' > src/checkout/shipping.ts
git add -A; GIT_AUTHOR_DATE="2026-10-21T15:40:00" GIT_COMMITTER_DATE="2026-10-21T15:40:00" git commit -qm "feat(checkout): free shipping threshold"
sed -i '' 's/Storefront for ACME Corp./Storefront for ACME Corp. Run `npm run dev`./' README.md
git add -A; GIT_AUTHOR_DATE="2026-10-22T09:05:00" GIT_COMMITTER_DATE="2026-10-22T09:05:00" git commit -qm "docs: how to run locally"
GIT_COMMITTER_NAME="Grace Hopper" GIT_AUTHOR_NAME="Grace Hopper" GIT_AUTHOR_EMAIL=grace@example.com
printf 'export function Spinner() {\n  return <span className="spinner" aria-busy="true" />;\n}\n' > src/ui/Spinner.tsx
git add -A; GIT_AUTHOR_NAME="Grace Hopper" GIT_AUTHOR_EMAIL=grace@example.com GIT_AUTHOR_DATE="2026-10-23T11:30:00" GIT_COMMITTER_DATE="2026-10-23T11:30:00" git commit -qm "feat(ui): loading spinner"
git branch feat/search-bar
git branch fix/currency-rounding
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
[ -n "${TYPESCRIPT_DIR:-}" ] && cp -R "$TYPESCRIPT_DIR" "$W/node_modules/typescript"

# --- api: a second project (Go-ish service).
A="$R/work/api"
mkdir -p "$A/cmd/server" "$A/internal/orders"
cd "$A"; git init -q -b main
printf 'module example.com/api\n\ngo 1.23\n' > go.mod
printf 'package main\n\nfunc main() {\n\tserve(":8080")\n}\n' > cmd/server/main.go
printf 'package orders\n\ntype Order struct {\n\tID    string\n\tTotal int64\n}\n' > internal/orders/order.go
git add -A; GIT_AUTHOR_DATE="2026-10-19T12:00:00" GIT_COMMITTER_DATE="2026-10-19T12:00:00" git commit -qm "Initial API service"

# --- Past conversations for the Sessions view (fixture ~/.claude/projects).
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
conv "$W" 6b1f0c2e-1a2b-4c3d-8e9f-000000000001 "Add a discount code field to the checkout" 2026-10-24 main 24
conv "$W" 6b1f0c2e-1a2b-4c3d-8e9f-000000000002 "Why does the cart total round 0.1 + 0.2 wrong?" 2026-10-23 fix/currency-rounding 12
conv "$W" 6b1f0c2e-1a2b-4c3d-8e9f-000000000003 "Build a search bar with keyboard navigation" 2026-10-22 feat/search-bar 40
conv "$W" 6b1f0c2e-1a2b-4c3d-8e9f-000000000004 "Write tests for formatPrice in EUR and USD" 2026-10-21 main 16
conv "$W" 6b1f0c2e-1a2b-4c3d-8e9f-000000000005 "Refactor Summary into smaller components" 2026-10-20 main 8
cx() { # id title date branch
  local d="$R/codex/sessions/2026/10/$(echo $3 | cut -c9-10)"; mkdir -p "$d"; local f="$d/rollout-$3T10-00-00-$1.jsonl"
  printf '{"timestamp":"%sT10:00:00.000Z","type":"session_meta","payload":{"id":"%s","cwd":"%s","git":{"branch":"%s"}}}\n' "$3" "$1" "$W" "$4" > "$f"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf '{"timestamp":"%sT10:%02d:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"%s"}}\n{"timestamp":"%sT10:%02d:30.000Z","type":"event_msg","payload":{"type":"agent_message","message":"ok"}}\n' "$3" $i "$2" "$3" $i >> "$f"
  done
}
cx 7c2a1d3e-2b3c-4d5e-9f00-000000000011 "Review the checkout flow for accessibility issues" 2026-10-24 main
cx 7c2a1d3e-2b3c-4d5e-9f00-000000000012 "Migrate the cart store to a reducer" 2026-10-22 main
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
printf 'Host devbox\n  HostName devbox.example.com\n  User dev\n' > "$R/sshd/config"
echo "fixture ready at $R"
