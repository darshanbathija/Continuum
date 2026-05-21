#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// Mirror of the JSX `DEMO_REPOS`, `DEMO_THREAD`, `DEMO_PLAN`, `LIVE_DATA`,
/// `CHAT_THREAD`, `RANGES`, `HISTORY` constants from the design source.
/// These are visual fixtures only — the live app will replace them with
/// real models (UsageHistoryStore, RepoIdentity, ChatProviderProbe…).
///
/// Kept verbatim so the verifier agent can diff JSX literals against
/// Swift literals 1:1.
public enum TahoeDemo {

    // MARK: - Repos / sessions / recents (Code IDE + iOS Code)

    public struct DemoSession: Hashable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var agent: TahoeProvider
        public var model: String
        public var status: DemoStatus
        public var mode: String  // plan | edit
        public var subtitle: String
    }
    public struct DemoRecent: Hashable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var provider: TahoeProvider
        public var live: Bool
        public var ago: String
    }
    public enum DemoStatus: String, Sendable { case running, paused, done, planning, degraded }
    public struct DemoRepo: Hashable, Identifiable, Sendable {
        public var id: String { key }
        public var key: String
        public var name: String
        public var tint: OKLCH
        public var live: Int
        public var sessions: [DemoSession]
        public var recents: [DemoRecent]
    }

    public static let repos: [DemoRepo] = [
        DemoRepo(
            key: "defx-frontend", name: "defx-frontend",
            tint: OKLCH(l: 0.72, c: 0.16, h: 35),
            live: 2,
            sessions: [
                DemoSession(id: "s1", title: "Refactor settlement store dedupe", agent: .claude, model: "Sonnet 4.5", status: .running, mode: "plan", subtitle: "plan · 2m ago"),
                DemoSession(id: "s2", title: "Add USDT pair to order book",     agent: .codex,  model: "gpt-5",      status: .paused,  mode: "edit", subtitle: "paused · 18m"),
                DemoSession(id: "s3", title: "Wire WS reconnect backoff",       agent: .claude, model: "Opus 4",     status: .done,    mode: "edit", subtitle: "done · 1h"),
            ],
            recents: [
                DemoRecent(id: "r1", title: "fix(perp): margin tier rounding", provider: .claude, live: true, ago: "now"),
                DemoRecent(id: "r2", title: "investigate flaky e2e suite",     provider: .codex,  live: false, ago: "12m"),
            ]
        ),
        DemoRepo(
            key: "ccwatch", name: "ccwatch",
            tint: OKLCH(l: 0.72, c: 0.16, h: 220),
            live: 0,
            sessions: [
                DemoSession(id: "s4", title: "Tahoe-style redesign pass", agent: .claude, model: "Sonnet 4.5", status: .planning, mode: "plan", subtitle: "planning · just now"),
            ],
            recents: []
        ),
        DemoRepo(
            key: "internal-tools", name: "internal-tools",
            tint: OKLCH(l: 0.72, c: 0.18, h: 310),
            live: 0, sessions: [], recents: []
        ),
    ]

    // MARK: - Demo thread (Code IDE + iOS Session Detail)

    public enum DemoThreadMsg: Hashable, Sendable {
        case user(String)
        case tool(name: String, target: String, detail: String)
        case assistant(String)
    }

    public static let thread: [DemoThreadMsg] = [
        .user("There's a dedupe bug in the settlement-store — same fill ID is getting written twice when two CLIs hit it within ~5ms. Plan a fix, then implement."),
        .tool(name: "read", target: "apps/web/src/lib/settlement-store.ts", detail: "184 lines"),
        .tool(name: "grep", target: "\"writeSettlement\\(\"", detail: "11 matches across 4 files"),
        .assistant("Found it. `writeSettlement` reads-then-writes without an atomic guard. Under concurrent CLI writers we lose the lock. I'll lift the dedupe key check into a single `INSERT … ON CONFLICT DO NOTHING` and add a regression test that fires 200 parallel writes."),
    ]

    public static let plan: [String] = [
        "Replace the read-modify-write in `writeSettlement` with `INSERT … ON CONFLICT (fill_id) DO NOTHING`.",
        "Add a unique index on `settlements.fill_id` if missing (migration `20260518_settlements_fill_id_unique`).",
        "Lift the in-memory `Set<string>` cache up to the daemon scope so worktree-cloned writers share it.",
        "Regression test: spawn 200 concurrent writes of the same fill, assert exactly one row.",
        "Run the existing `pnpm test --filter @defx/settlement` suite + the new test, attach output to PR.",
    ]

    // MARK: - Per-provider live data (Live tab)

    public struct LiveData: Sendable {
        public var session: Double
        public var weekly: Double
        public var resetIn: String
        public var weeklyIn: String
        public var window: String
        public var reviveOn: Bool
        public var reviveAgo: String
    }

    public static let liveData: [TahoeProvider: LiveData] = [
        .claude: LiveData(session: 67, weekly: 42, resetIn: "2h 18m", weeklyIn: "4d 6h", window: "5h", reviveOn: true,  reviveAgo: "4h ago"),
        .codex:  LiveData(session: 34, weekly: 28, resetIn: "4h 02m", weeklyIn: "6d 1h", window: "5h", reviveOn: true,  reviveAgo: "3h ago"),
        .gemini: LiveData(session: 89, weekly: 61, resetIn: "58m",    weeklyIn: "5d 2h", window: "5h", reviveOn: true,  reviveAgo: "2h ago"),
    ]

    // MARK: - Chat history

    public struct ChatHistory: Hashable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var ago: String
        public var winners: [TahoeProvider]
        public var turns: Int
        public var active: Bool
    }

    public static let chatHistory: [ChatHistory] = [
        ChatHistory(id: "c1", title: "react-query refactor + tradeoffs",       ago: "just now",  winners: [.claude, .codex], turns: 2, active: true),
        ChatHistory(id: "c2", title: "sketch a 5-step plan for the settlement dedupe", ago: "2h", winners: [.claude],                turns: 4, active: false),
        ChatHistory(id: "c3", title: "explain CRDTs for trading positions",    ago: "yesterday", winners: [.gemini],                  turns: 6, active: false),
        ChatHistory(id: "c4", title: "rewrite this regex with comments",       ago: "yesterday", winners: [.codex],                   turns: 1, active: false),
        ChatHistory(id: "c5", title: "which model is best at SQL",             ago: "2 days ago",winners: [.codex, .codex],          turns: 3, active: false),
        ChatHistory(id: "c6", title: "name suggestions for the staking primitive", ago: "3 days ago", winners: [.claude, .gemini, .claude], turns: 8, active: false),
        ChatHistory(id: "c7", title: "k8s rollout debugging tips",             ago: "last week", winners: [.gemini],                  turns: 5, active: false),
    ]

    // MARK: - Chat thread for the Mac Chat hero

    public struct ChatReply: Hashable, Sendable {
        public var model: String
        public var tokens: Int
        public var cost: Double
        public var time: Double
        public var starred: Bool
        public var blocks: [ChatBlock]
    }
    public enum ChatBlock: Hashable, Sendable {
        case paragraph(String)
        case code(lang: String, text: String)
    }
    public struct ChatTurn: Hashable, Identifiable, Sendable {
        public var id = UUID()
        public var user: String
        public var attached: [Attached]
        public var replies: [TahoeProvider: ChatReply]
    }
    public struct Attached: Hashable, Sendable {
        public var name: String
        public var range: String
    }
    public struct ChatThread: Hashable, Sendable {
        public var title: String
        public var turns: [ChatTurn]
    }

    public static let chatThread = ChatThread(
        title: "react-query refactor + tradeoffs",
        turns: [
            ChatTurn(
                user: "I've got a gnarly useEffect-fetch in apps/web/src/lib/orders.ts — refactor it to react-query and walk me through the tradeoffs (cache, retries, SSR).",
                attached: [Attached(name: "orders.ts", range: "1-84")],
                replies: [
                    .claude: ChatReply(
                        model: "Sonnet 4.5", tokens: 1284, cost: 0.011, time: 4.2, starred: true,
                        blocks: [
                            .paragraph("I'd lift the fetcher out and let react-query own loading, caching, and retry. Key tradeoff: you trade direct control over the request lifecycle for a global cache that bisects every component using the same key."),
                            .code(lang: "ts", text: """
export const ordersKey = (org: string) => ['orders', org] as const;

export function useOrders(org: string) {
  return useQuery({
    queryKey: ordersKey(org),
    queryFn: () => api.orders.list(org),
    staleTime: 30_000,
    retry: (n, err) => n < 2 && !isFatalAuth(err),
  });
}
"""),
                            .paragraph("Three things to watch: (1) SSR — hydrate via dehydrate/Hydrate on the server, (2) mutations should invalidate the key not refetch manually, (3) staleTime > 0 saves you from a re-render storm when 6 widgets mount together."),
                        ]
                    ),
                    .codex: ChatReply(
                        model: "gpt-5", tokens: 962, cost: 0.008, time: 3.1, starred: false,
                        blocks: [
                            .paragraph("Drop in useQuery; gc default is fine."),
                            .code(lang: "ts", text: """
export const useOrders = (org: string) =>
  useQuery(['orders', org], () => api.orders.list(org));
"""),
                            .paragraph("For SSR call queryClient.prefetchQuery on the server. For mutations: invalidateQueries([\"orders\"]). Retries are on by default — disable if your backend is non-idempotent."),
                        ]
                    ),
                    .gemini: ChatReply(
                        model: "antigravity-pro", tokens: 1840, cost: 0.014, time: 5.6, starred: false,
                        blocks: [
                            .paragraph("Refactoring useEffect-fetch is one of the highest-leverage moves you can make in a Next.js app. Below is the migration plus a checklist of every place the behavior changes."),
                            .code(lang: "ts", text: """
// hooks/use-orders.ts
import { useQuery } from '@tanstack/react-query';
import { api } from '@/lib/api';

export function useOrders(org: string) {
  return useQuery({
    queryKey: ['orders', org],
    queryFn: ({ signal }) => api.orders.list(org, { signal }),
    staleTime: 30 * 1000,
    refetchOnWindowFocus: true,
    retry: 2,
  });
}
"""),
                            .paragraph("Tradeoffs to surface to your team: deduped requests across the tree, automatic AbortController via signal, background refetches you may not have signed up for, and a hidden cache that holds memory until gcTime expires."),
                        ]
                    ),
                ]
            ),
            ChatTurn(
                user: "Good. Now what about SSR specifically — we use the app router. Show me the boundary.",
                attached: [],
                replies: [
                    .claude: ChatReply(
                        model: "Sonnet 4.5", tokens: 740, cost: 0.006, time: 2.4, starred: false,
                        blocks: [
                            .paragraph("Prefetch in the RSC, then dehydrate into a HydrationBoundary so the client picks up the same cache."),
                            .code(lang: "tsx", text: """
// app/(dash)/orders/page.tsx
const qc = new QueryClient();
await qc.prefetchQuery({ queryKey: ordersKey(org), queryFn: ... });
return (
  <HydrationBoundary state={dehydrate(qc)}>
    <OrdersTable org={org} />
  </HydrationBoundary>
);
"""),
                        ]
                    ),
                    .codex: ChatReply(
                        model: "gpt-5", tokens: 410, cost: 0.003, time: 1.7, starred: true,
                        blocks: [
                            .paragraph("Prefetch server-side, dehydrate, hydrate on client. Standard pattern — see @tanstack/react-query/server docs for the canonical boundary."),
                            .code(lang: "tsx", text: """
<HydrationBoundary state={dehydrate(qc)}>
  <OrdersTable />
</HydrationBoundary>
"""),
                        ]
                    ),
                    .gemini: ChatReply(
                        model: "antigravity-pro", tokens: 1220, cost: 0.009, time: 4.1, starred: false,
                        blocks: [
                            .paragraph("In app router you have two layers: the server component prefetches, the client component consumes. Critically you should NOT share a QueryClient across requests on the server — instantiate one per request."),
                            .code(lang: "tsx", text: """
// app/(dash)/orders/page.tsx — server
import { dehydrate, HydrationBoundary, QueryClient } from '@tanstack/react-query';
import { OrdersTable } from './OrdersTable.client';

export default async function Page({ params }: { params: { org: string }}) {
  const qc = new QueryClient();
  await qc.prefetchQuery({
    queryKey: ['orders', params.org],
    queryFn: () => fetchOrders(params.org),
  });
  return (
    <HydrationBoundary state={dehydrate(qc)}>
      <OrdersTable org={params.org} />
    </HydrationBoundary>
  );
}
"""),
                        ]
                    ),
                ]
            ),
        ]
    )

    // MARK: - Range analytics

    public struct SpendPoint: Sendable {
        public var c: Double  // claude
        public var x: Double  // codex
        public var g: Double  // gemini
    }
    public struct SpendRepo: Sendable {
        public var name: String
        public var c: Double
        public var x: Double
        public var g: Double
    }
    public struct Totals: Sendable {
        public var c: String
        public var x: String
        public var g: String
        public var all: String
        public var delta: String
    }
    public struct RangeData: Sendable {
        public var label: String
        public var ticks: [String]
        public var series: [SpendPoint]
        public var total: Totals
        public var repos: [SpendRepo]
    }

    public static let ranges: [String: RangeData] = [
        "24h": RangeData(
            label: "24h",
            ticks: ["00","04","08","12","16","20"],
            series: [
                SpendPoint(c: 0.4, x: 0.2, g: 0.1), SpendPoint(c: 0.6, x: 0.3, g: 0.0),
                SpendPoint(c: 1.2, x: 0.6, g: 0.2), SpendPoint(c: 1.8, x: 0.9, g: 0.3),
                SpendPoint(c: 1.4, x: 0.7, g: 0.1), SpendPoint(c: 0.5, x: 0.2, g: 0.0),
            ],
            total: Totals(c: "$5.92", x: "$2.94", g: "$0.71", all: "$9.57", delta: "+22%"),
            repos: [
                SpendRepo(name: "defx-frontend",  c: 3.84, x: 1.42, g: 0.36),
                SpendRepo(name: "ccwatch",        c: 0.88, x: 0.74, g: 0.21),
                SpendRepo(name: "internal-tools", c: 0.62, x: 0.48, g: 0.08),
                SpendRepo(name: "docs-site",      c: 0.30, x: 0.18, g: 0.04),
                SpendRepo(name: "Other",          c: 0.28, x: 0.12, g: 0.02),
            ]
        ),
        "7d": RangeData(
            label: "7d",
            ticks: ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],
            series: [
                SpendPoint(c: 3.2, x: 1.4, g: 0.4), SpendPoint(c: 4.1, x: 2.2, g: 0.5),
                SpendPoint(c: 5.6, x: 1.8, g: 0.6), SpendPoint(c: 2.8, x: 0.9, g: 0.3),
                SpendPoint(c: 4.4, x: 2.6, g: 0.7), SpendPoint(c: 1.6, x: 0.8, g: 0.2),
                SpendPoint(c: 2.5, x: 2.2, g: 0.5),
            ],
            total: Totals(c: "$24.18", x: "$11.94", g: "$3.20", all: "$39.32", delta: "+14%"),
            repos: [
                SpendRepo(name: "defx-frontend",  c: 11.20, x: 5.10, g: 1.12),
                SpendRepo(name: "ccwatch",        c: 2.42,  x: 1.40, g: 0.36),
                SpendRepo(name: "internal-tools", c: 1.10,  x: 0.78, g: 0.16),
                SpendRepo(name: "docs-site",      c: 0.52,  x: 0.30, g: 0.10),
                SpendRepo(name: "Other",          c: 0.46,  x: 0.22, g: 0.08),
            ]
        ),
        "30d": RangeData(
            label: "30d",
            ticks: ["W1","W2","W3","W4"],
            series: [
                SpendPoint(c: 22.4, x: 9.1, g: 2.0),  SpendPoint(c: 18.6, x: 11.2, g: 2.4),
                SpendPoint(c: 26.8, x: 13.0, g: 3.6), SpendPoint(c: 24.2, x: 10.8, g: 3.1),
            ],
            total: Totals(c: "$92.00", x: "$44.10", g: "$11.10", all: "$147.20", delta: "+9%"),
            repos: [
                SpendRepo(name: "defx-frontend",  c: 42.10, x: 19.40, g: 4.10),
                SpendRepo(name: "ccwatch",        c: 16.20, x: 8.40,  g: 2.20),
                SpendRepo(name: "internal-tools", c: 11.40, x: 6.80,  g: 1.60),
                SpendRepo(name: "docs-site",      c: 4.10,  x: 1.90,  g: 0.80),
                SpendRepo(name: "Other",          c: 3.20,  x: 1.10,  g: 0.40),
            ]
        ),
        "90d": RangeData(
            label: "90d",
            ticks: ["Mar","Apr","May"],
            series: [
                SpendPoint(c: 64.2, x: 28.0, g: 6.8), SpendPoint(c: 88.4, x: 41.0, g: 9.6),
                SpendPoint(c: 92.0, x: 44.1, g: 11.1),
            ],
            total: Totals(c: "$244.60", x: "$113.10", g: "$27.50", all: "$385.20", delta: "+18%"),
            repos: [
                SpendRepo(name: "defx-frontend",  c: 112.40, x: 49.10, g: 11.20),
                SpendRepo(name: "ccwatch",        c: 44.20,  x: 22.80, g: 6.10),
                SpendRepo(name: "internal-tools", c: 28.40,  x: 18.60, g: 4.20),
                SpendRepo(name: "docs-site",      c: 12.80,  x: 6.40,  g: 2.40),
                SpendRepo(name: "Other",          c: 8.20,   x: 4.60,  g: 1.10),
            ]
        ),
        "all": RangeData(
            label: "all time",
            ticks: ["Q1 \u{2019}25", "Q2", "Q3", "Q4", "Q1 \u{2019}26", "Q2"],
            series: [
                SpendPoint(c: 142.0, x: 60.4, g: 12.2),  SpendPoint(c: 188.6, x: 84.0, g: 18.4),
                SpendPoint(c: 214.2, x: 96.8, g: 22.0),  SpendPoint(c: 256.4, x: 108.2, g: 26.6),
                SpendPoint(c: 244.6, x: 113.1, g: 27.5), SpendPoint(c: 312.8, x: 138.4, g: 34.0),
            ],
            total: Totals(c: "$1,358.60", x: "$600.90", g: "$140.70", all: "$2,100.20", delta: "+24%"),
            repos: [
                SpendRepo(name: "defx-frontend",  c: 612.40, x: 264.10, g: 60.20),
                SpendRepo(name: "ccwatch",        c: 244.20, x: 122.80, g: 32.10),
                SpendRepo(name: "internal-tools", c: 168.40, x: 94.60,  g: 22.20),
                SpendRepo(name: "docs-site",      c: 82.80,  x: 36.40,  g: 12.40),
                SpendRepo(name: "Other",          c: 48.20,  x: 22.60,  g: 6.10),
            ]
        ),
    ]
}

/// Tiny number formatter — token counts.
public func tahoeFmtTok(_ n: Int) -> String {
    if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000.0) }
    return "\(n)"
}
#endif
