<template>
    <main class="p-6">
        <div class="flex items-center gap-3 mb-8">
            <h2 class="text-lg font-semibold text-foreground">
                Design Preview
            </h2>
            <div class="flex gap-1">
                <button
                    v-for="theme in themes"
                    :key="theme.id"
                    class="px-3 py-1.5 text-sm rounded transition-colors"
                    :class="
                        activeTheme === theme.id
                            ? 'bg-primary text-primary-foreground'
                            : 'text-muted-foreground hover:text-foreground hover:bg-secondary'
                    "
                    @click="activeTheme = theme.id"
                >
                    {{ theme.label }}
                </button>
            </div>
        </div>

        <!-- Forge Theme -->
        <div v-if="activeTheme === 'forge'" class="forge-theme">
            <div
                class="grid grid-cols-1 lg:grid-cols-4 gap-5 h-[calc(100vh-160px)]"
            >
                <aside class="lg:col-span-1 space-y-5 overflow-y-auto">
                    <!-- Account Card -->
                    <div class="forge-card p-4">
                        <h3
                            class="text-xs font-semibold uppercase tracking-widest text-amber-500/80 mb-3"
                        >
                            Account
                        </h3>
                        <div class="space-y-2">
                            <div class="flex justify-between text-sm">
                                <span class="text-[#8a8a9a]">Balance</span>
                                <span class="font-mono text-foreground"
                                    >$100,000.00</span
                                >
                            </div>
                            <div class="flex justify-between text-sm">
                                <span class="text-[#8a8a9a]"
                                    >Unrealized P&L</span
                                >
                                <span class="font-mono text-emerald-400"
                                    >$0.00</span
                                >
                            </div>
                            <div class="flex justify-between text-sm">
                                <span class="text-[#8a8a9a]"
                                    >Margin Available</span
                                >
                                <span class="font-mono text-foreground"
                                    >$100,000.00</span
                                >
                            </div>
                        </div>
                    </div>

                    <!-- Price Cards -->
                    <div class="space-y-2">
                        <h3
                            class="text-xs font-semibold uppercase tracking-widest text-amber-500/80"
                        >
                            Live Prices
                        </h3>
                        <div
                            v-for="pair in mockPrices"
                            :key="pair.instrument"
                            class="forge-card-interactive p-3 cursor-pointer"
                            :class="pair.selected ? 'forge-card-selected' : ''"
                        >
                            <div
                                class="flex items-center justify-between mb-1.5"
                            >
                                <span
                                    class="text-sm font-semibold text-foreground"
                                    >{{ pair.instrument }}</span
                                >
                                <span
                                    class="text-[10px] text-[#6a6a7a] font-mono"
                                    >{{ pair.time }}</span
                                >
                            </div>
                            <div class="grid grid-cols-3 gap-2 text-xs">
                                <div>
                                    <div class="text-[#6a6a7a] mb-0.5">Bid</div>
                                    <div class="font-mono text-emerald-400">
                                        {{ pair.bid }}
                                    </div>
                                </div>
                                <div>
                                    <div class="text-[#6a6a7a] mb-0.5">Ask</div>
                                    <div class="font-mono text-foreground">
                                        {{ pair.ask }}
                                    </div>
                                </div>
                                <div>
                                    <div class="text-[#6a6a7a] mb-0.5">
                                        Spread
                                    </div>
                                    <div class="font-mono text-[#6a6a7a]">
                                        {{ pair.spread }}
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                </aside>

                <!-- Chart Area -->
                <div
                    class="lg:col-span-3 forge-card overflow-hidden flex flex-col"
                >
                    <div
                        class="flex items-center justify-between border-b border-amber-500/10 px-4 py-2.5"
                    >
                        <div class="flex items-center gap-3">
                            <span class="text-sm font-semibold text-foreground"
                                >EUR/USD</span
                            >
                            <div class="flex gap-1">
                                <span
                                    v-for="tf in [
                                        '1m',
                                        '5m',
                                        '15m',
                                        '1H',
                                        '4H',
                                        'D',
                                    ]"
                                    :key="tf"
                                    class="px-2 py-0.5 text-[11px] rounded cursor-pointer transition-colors"
                                    :class="
                                        tf === '15m'
                                            ? 'bg-amber-500/20 text-amber-400'
                                            : 'text-[#6a6a7a] hover:text-foreground'
                                    "
                                    >{{ tf }}</span
                                >
                            </div>
                        </div>
                    </div>
                    <div
                        class="flex-1 flex items-center justify-center text-[#4a4a5a] text-sm"
                    >
                        Chart renders here
                    </div>
                </div>
            </div>
        </div>

        <!-- Terminal Theme -->
        <div v-if="activeTheme === 'terminal'" class="terminal-theme">
            <div
                class="grid grid-cols-1 lg:grid-cols-4 gap-3 h-[calc(100vh-160px)]"
            >
                <aside class="lg:col-span-1 space-y-3 overflow-y-auto">
                    <!-- Account Card -->
                    <div class="terminal-card p-3">
                        <div
                            class="text-[10px] uppercase tracking-widest text-green-500 mb-2 font-mono"
                        >
                            // account
                        </div>
                        <div class="space-y-1 font-mono text-xs">
                            <div class="flex justify-between">
                                <span class="text-neutral-500">BAL</span>
                                <span class="text-neutral-200"
                                    >100,000.00 CAD</span
                                >
                            </div>
                            <div class="flex justify-between">
                                <span class="text-neutral-500">UPL</span>
                                <span class="text-green-400">+0.00</span>
                            </div>
                            <div class="flex justify-between">
                                <span class="text-neutral-500">MGN</span>
                                <span class="text-neutral-200">100,000.00</span>
                            </div>
                            <div class="flex justify-between">
                                <span class="text-neutral-500">POS</span>
                                <span class="text-neutral-200">0</span>
                            </div>
                        </div>
                    </div>

                    <!-- Price Cards -->
                    <div class="terminal-card p-3">
                        <div
                            class="text-[10px] uppercase tracking-widest text-green-500 mb-2 font-mono"
                        >
                            // prices
                        </div>
                        <table class="w-full font-mono text-xs">
                            <thead>
                                <tr class="text-neutral-600">
                                    <th class="text-left pb-1">PAIR</th>
                                    <th class="text-right pb-1">BID</th>
                                    <th class="text-right pb-1">ASK</th>
                                </tr>
                            </thead>
                            <tbody>
                                <tr
                                    v-for="pair in mockPrices"
                                    :key="pair.instrument"
                                    class="cursor-pointer hover:bg-green-500/5 transition-colors"
                                    :class="
                                        pair.selected ? 'bg-green-500/10' : ''
                                    "
                                >
                                    <td class="py-1 text-neutral-300">
                                        {{ pair.instrument }}
                                    </td>
                                    <td class="py-1 text-right text-green-400">
                                        {{ pair.bid }}
                                    </td>
                                    <td
                                        class="py-1 text-right text-neutral-300"
                                    >
                                        {{ pair.ask }}
                                    </td>
                                </tr>
                            </tbody>
                        </table>
                    </div>
                </aside>

                <!-- Chart Area -->
                <div
                    class="lg:col-span-3 terminal-card overflow-hidden flex flex-col"
                >
                    <div
                        class="flex items-center justify-between border-b border-green-500/10 px-3 py-2"
                    >
                        <div class="flex items-center gap-4 font-mono">
                            <span class="text-xs text-neutral-200"
                                >EUR_USD</span
                            >
                            <div class="flex gap-2">
                                <span
                                    v-for="tf in [
                                        'M1',
                                        'M5',
                                        'M15',
                                        'H1',
                                        'H4',
                                        'D',
                                    ]"
                                    :key="tf"
                                    class="text-[10px] cursor-pointer transition-colors"
                                    :class="
                                        tf === 'M15'
                                            ? 'text-green-400'
                                            : 'text-neutral-600 hover:text-neutral-300'
                                    "
                                    >{{ tf }}</span
                                >
                            </div>
                        </div>
                        <span class="text-[10px] text-neutral-600 font-mono"
                            >OANDA:PRACTICE</span
                        >
                    </div>
                    <div
                        class="flex-1 flex items-center justify-center text-neutral-700 text-xs font-mono"
                    >
                        &gt; chart_render --instrument=EUR_USD --tf=M15
                    </div>
                </div>
            </div>
        </div>

        <!-- Meridian Theme -->
        <div v-if="activeTheme === 'meridian'" class="meridian-theme">
            <div
                class="grid grid-cols-1 lg:grid-cols-4 gap-5 h-[calc(100vh-160px)]"
            >
                <aside class="lg:col-span-1 space-y-5 overflow-y-auto">
                    <!-- Account Card -->
                    <div class="meridian-card p-4">
                        <h3
                            class="text-xs font-medium uppercase tracking-wider text-blue-400/70 mb-3"
                        >
                            Account
                        </h3>
                        <div class="space-y-2.5">
                            <div class="flex justify-between text-sm">
                                <span class="text-slate-500">Balance</span>
                                <span class="font-mono text-slate-200"
                                    >$100,000.00</span
                                >
                            </div>
                            <div class="flex justify-between text-sm">
                                <span class="text-slate-500"
                                    >Unrealized P&L</span
                                >
                                <span class="font-mono text-emerald-400"
                                    >$0.00</span
                                >
                            </div>
                            <div class="flex justify-between text-sm">
                                <span class="text-slate-500"
                                    >Margin Available</span
                                >
                                <span class="font-mono text-slate-200"
                                    >$100,000.00</span
                                >
                            </div>
                        </div>
                    </div>

                    <!-- Price Cards -->
                    <div class="space-y-2.5">
                        <h3
                            class="text-xs font-medium uppercase tracking-wider text-blue-400/70"
                        >
                            Live Prices
                        </h3>
                        <div
                            v-for="pair in mockPrices"
                            :key="pair.instrument"
                            class="meridian-card-interactive p-3 cursor-pointer"
                            :class="
                                pair.selected ? 'meridian-card-selected' : ''
                            "
                        >
                            <div
                                class="flex items-center justify-between mb-1.5"
                            >
                                <span
                                    class="text-sm font-medium text-slate-200"
                                    >{{ pair.instrument }}</span
                                >
                                <span
                                    class="text-[10px] text-slate-600 font-mono"
                                    >{{ pair.time }}</span
                                >
                            </div>
                            <div class="grid grid-cols-3 gap-2 text-xs">
                                <div>
                                    <div class="text-slate-600 mb-0.5">Bid</div>
                                    <div class="font-mono text-emerald-400">
                                        {{ pair.bid }}
                                    </div>
                                </div>
                                <div>
                                    <div class="text-slate-600 mb-0.5">Ask</div>
                                    <div class="font-mono text-slate-300">
                                        {{ pair.ask }}
                                    </div>
                                </div>
                                <div>
                                    <div class="text-slate-600 mb-0.5">
                                        Spread
                                    </div>
                                    <div class="font-mono text-slate-600">
                                        {{ pair.spread }}
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                </aside>

                <!-- Chart Area -->
                <div
                    class="lg:col-span-3 meridian-card overflow-hidden flex flex-col"
                >
                    <div
                        class="flex items-center justify-between border-b border-blue-400/10 px-4 py-2.5"
                    >
                        <div class="flex items-center gap-3">
                            <span class="text-sm font-medium text-slate-200"
                                >EUR/USD</span
                            >
                            <div class="flex gap-1">
                                <span
                                    v-for="tf in [
                                        '1m',
                                        '5m',
                                        '15m',
                                        '1H',
                                        '4H',
                                        'D',
                                    ]"
                                    :key="tf"
                                    class="px-2 py-0.5 text-[11px] rounded cursor-pointer transition-colors"
                                    :class="
                                        tf === '15m'
                                            ? 'bg-blue-500/15 text-blue-400'
                                            : 'text-slate-600 hover:text-slate-300'
                                    "
                                    >{{ tf }}</span
                                >
                            </div>
                        </div>
                    </div>
                    <div
                        class="flex-1 flex items-center justify-center text-slate-700 text-sm"
                    >
                        Chart renders here
                    </div>
                </div>
            </div>
        </div>

        <!-- Forge + Terminal Theme -->
        <div v-if="activeTheme === 'forge-terminal'" class="ft-theme">
            <div
                class="grid grid-cols-1 lg:grid-cols-4 gap-4 h-[calc(100vh-160px)]"
            >
                <aside class="lg:col-span-1 space-y-4 overflow-y-auto">
                    <!-- Account Card -->
                    <div class="ft-card p-3">
                        <div
                            class="text-[10px] uppercase tracking-widest text-amber-500/70 mb-2 font-mono"
                        >
                            // account
                        </div>
                        <div class="space-y-1 font-mono text-xs">
                            <div class="flex justify-between">
                                <span class="text-muted-foreground">BAL</span>
                                <span class="text-foreground"
                                    >100,000.00 CAD</span
                                >
                            </div>
                            <div class="flex justify-between">
                                <span class="text-muted-foreground">UPL</span>
                                <span class="text-emerald-400">+0.00</span>
                            </div>
                            <div class="flex justify-between">
                                <span class="text-muted-foreground">RPL</span>
                                <span class="text-emerald-400">+0.00</span>
                            </div>
                            <div class="border-t border-amber-500/8 my-1.5" />
                            <div class="flex justify-between">
                                <span class="text-muted-foreground">MGN.USED</span>
                                <span class="text-foreground">0.00</span>
                            </div>
                            <div class="flex justify-between">
                                <span class="text-muted-foreground">MGN.AVAIL</span>
                                <span class="text-foreground">100,000.00</span>
                            </div>
                            <div class="flex justify-between">
                                <span class="text-muted-foreground">POS</span>
                                <span class="text-foreground">0</span>
                            </div>
                        </div>
                    </div>

                    <!-- Price Table -->
                    <div class="ft-card p-3">
                        <div
                            class="text-[10px] uppercase tracking-widest text-amber-500/70 mb-2 font-mono"
                        >
                            // prices
                        </div>
                        <table class="w-full font-mono text-xs">
                            <thead>
                                <tr class="text-[#4a4a5a]">
                                    <th class="text-left pb-1.5 text-[10px]">
                                        PAIR
                                    </th>
                                    <th class="text-right pb-1.5 text-[10px]">
                                        BID
                                    </th>
                                    <th class="text-right pb-1.5 text-[10px]">
                                        ASK
                                    </th>
                                    <th class="text-right pb-1.5 text-[10px]">
                                        SPRD
                                    </th>
                                </tr>
                            </thead>
                            <tbody>
                                <tr
                                    v-for="pair in mockPrices"
                                    :key="pair.instrument"
                                    class="cursor-pointer transition-all duration-150"
                                    :class="
                                        pair.selected
                                            ? 'ft-row-selected'
                                            : 'ft-row'
                                    "
                                >
                                    <td class="py-1.5 text-[#c8c4bd]">
                                        {{ pair.instrument }}
                                    </td>
                                    <td
                                        class="py-1.5 text-right text-emerald-400"
                                    >
                                        {{ pair.bid }}
                                    </td>
                                    <td
                                        class="py-1.5 text-right text-[#c8c4bd]"
                                    >
                                        {{ pair.ask }}
                                    </td>
                                    <td
                                        class="py-1.5 text-right text-[#4a4a5a]"
                                    >
                                        {{ pair.spread }}
                                    </td>
                                </tr>
                            </tbody>
                        </table>
                    </div>

                    <!-- Active Strategies -->
                    <div class="ft-card p-3">
                        <div
                            class="text-[10px] uppercase tracking-widest text-amber-500/70 mb-2 font-mono"
                        >
                            // strategies
                        </div>
                        <div class="space-y-2">
                            <div
                                class="flex items-center justify-between font-mono text-xs"
                            >
                                <div class="flex items-center gap-2">
                                    <span
                                        class="h-1.5 w-1.5 rounded-full bg-emerald-500 animate-pulse"
                                    />
                                    <span class="text-[#c8c4bd]"
                                        >EMA Cross EUR/USD</span
                                    >
                                </div>
                                <span class="text-[#4a4a5a]">M15</span>
                            </div>
                            <div
                                class="flex items-center justify-between font-mono text-xs"
                            >
                                <div class="flex items-center gap-2">
                                    <span
                                        class="h-1.5 w-1.5 rounded-full bg-[#3a3a4a]"
                                    />
                                    <span class="text-muted-foreground"
                                        >RSI Reversal XAU</span
                                    >
                                </div>
                                <span class="text-[#3a3a4a]">H1</span>
                            </div>
                        </div>
                    </div>
                </aside>

                <!-- Chart Area -->
                <div
                    class="lg:col-span-3 ft-card overflow-hidden flex flex-col"
                >
                    <div
                        class="flex items-center justify-between border-b border-amber-500/8 px-4 py-2"
                    >
                        <div class="flex items-center gap-4 font-mono">
                            <span class="text-xs text-foreground">EUR_USD</span>
                            <span class="text-[10px] text-[#4a4a5a]">|</span>
                            <div class="flex gap-2">
                                <span
                                    v-for="tf in [
                                        'M1',
                                        'M5',
                                        'M15',
                                        'H1',
                                        'H4',
                                        'D',
                                    ]"
                                    :key="tf"
                                    class="text-[10px] cursor-pointer transition-colors px-1.5 py-0.5 rounded"
                                    :class="
                                        tf === 'M15'
                                            ? 'text-amber-400 bg-primary/10'
                                            : 'text-[#4a4a5a] hover:text-[#c8c4bd]'
                                    "
                                    >{{ tf }}</span
                                >
                            </div>
                        </div>
                        <div
                            class="flex items-center gap-3 font-mono text-[10px]"
                        >
                            <span class="text-[#4a4a5a]"
                                >O
                                <span class="text-[#c8c4bd]"
                                    >1.16653</span
                                ></span
                            >
                            <span class="text-[#4a4a5a]"
                                >H
                                <span class="text-emerald-400"
                                    >1.16688</span
                                ></span
                            >
                            <span class="text-[#4a4a5a]"
                                >L
                                <span class="text-red-400">1.16621</span></span
                            >
                            <span class="text-[#4a4a5a]"
                                >C
                                <span class="text-[#c8c4bd]"
                                    >1.16670</span
                                ></span
                            >
                        </div>
                    </div>
                    <div
                        class="flex-1 flex items-center justify-center text-[#2a2a3a] text-xs font-mono"
                    >
                        &gt; rendering chart...
                    </div>
                    <!-- Status bar -->
                    <div
                        class="border-t border-amber-500/8 px-4 py-1.5 flex items-center justify-between font-mono text-[10px]"
                    >
                        <div class="flex items-center gap-3">
                            <span class="flex items-center gap-1.5">
                                <span
                                    class="h-1.5 w-1.5 rounded-full bg-emerald-500"
                                />
                                <span class="text-muted-foreground">STREAM</span>
                            </span>
                            <span class="text-[#3a3a4a]">|</span>
                            <span class="text-muted-foreground">OANDA:PRACTICE</span>
                        </div>
                        <span class="text-[#3a3a4a]">{{
                            new Date().toLocaleTimeString()
                        }}</span>
                    </div>
                </div>
            </div>
        </div>

        <!-- Forge Refined Theme -->
        <div v-if="activeTheme === 'forge-refined'" class="fr-theme">
            <div
                class="grid grid-cols-1 lg:grid-cols-4 gap-4 h-[calc(100vh-160px)]"
            >
                <aside class="lg:col-span-1 space-y-4 overflow-y-auto">
                    <!-- Account Card -->
                    <div class="fr-card p-4">
                        <div class="fr-section-label mb-3">Account</div>
                        <div class="space-y-2">
                            <div class="flex justify-between text-sm">
                                <span class="text-[#7a7a8a]">Balance</span>
                                <span class="font-mono text-foreground"
                                    >100,000.00 CAD</span
                                >
                            </div>
                            <div class="flex justify-between text-sm">
                                <span class="text-[#7a7a8a]"
                                    >Unrealized P&L</span
                                >
                                <span class="font-mono text-emerald-400"
                                    >+0.00</span
                                >
                            </div>
                            <div class="flex justify-between text-sm">
                                <span class="text-[#7a7a8a]">Realized P&L</span>
                                <span class="font-mono text-emerald-400"
                                    >+0.00</span
                                >
                            </div>
                            <div class="border-t border-amber-500/8 my-1" />
                            <div class="flex justify-between text-sm">
                                <span class="text-[#7a7a8a]">Margin Used</span>
                                <span class="font-mono text-foreground"
                                    >0.00</span
                                >
                            </div>
                            <div class="flex justify-between text-sm">
                                <span class="text-[#7a7a8a]"
                                    >Margin Available</span
                                >
                                <span class="font-mono text-foreground"
                                    >100,000.00</span
                                >
                            </div>
                            <div class="flex justify-between text-sm">
                                <span class="text-[#7a7a8a]"
                                    >Open Positions</span
                                >
                                <span class="font-mono text-foreground">0</span>
                            </div>
                        </div>
                    </div>

                    <!-- Price Table -->
                    <div class="fr-card p-4">
                        <div class="fr-section-label mb-3">Live Prices</div>
                        <table class="w-full text-xs">
                            <thead>
                                <tr class="text-[#4a4a5a]">
                                    <th
                                        class="text-left pb-2 text-[10px] font-medium uppercase tracking-wider"
                                    >
                                        Pair
                                    </th>
                                    <th
                                        class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                                    >
                                        Bid
                                    </th>
                                    <th
                                        class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                                    >
                                        Ask
                                    </th>
                                    <th
                                        class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                                    >
                                        Spread
                                    </th>
                                </tr>
                            </thead>
                            <tbody>
                                <tr
                                    v-for="pair in mockPrices"
                                    :key="pair.instrument"
                                    class="cursor-pointer transition-all duration-150"
                                    :class="
                                        pair.selected
                                            ? 'fr-row-selected'
                                            : 'fr-row'
                                    "
                                >
                                    <td class="py-1.5 text-[#c8c4bd] text-sm">
                                        {{ pair.instrument }}
                                    </td>
                                    <td
                                        class="py-1.5 text-right font-mono text-emerald-400"
                                    >
                                        {{ pair.bid }}
                                    </td>
                                    <td
                                        class="py-1.5 text-right font-mono text-[#c8c4bd]"
                                    >
                                        {{ pair.ask }}
                                    </td>
                                    <td
                                        class="py-1.5 text-right font-mono text-[#4a4a5a]"
                                    >
                                        {{ pair.spread }}
                                    </td>
                                </tr>
                            </tbody>
                        </table>
                    </div>

                    <!-- Active Strategies -->
                    <div class="fr-card p-4">
                        <div class="fr-section-label mb-3">Strategies</div>
                        <div class="space-y-2.5">
                            <div
                                class="flex items-center justify-between text-sm"
                            >
                                <div class="flex items-center gap-2">
                                    <span
                                        class="h-1.5 w-1.5 rounded-full bg-emerald-500 animate-pulse"
                                    />
                                    <span class="text-[#c8c4bd]"
                                        >EMA Cross</span
                                    >
                                </div>
                                <div class="flex items-center gap-2">
                                    <span class="text-muted-foreground text-xs"
                                        >EUR/USD</span
                                    >
                                    <span
                                        class="font-mono text-[10px] text-amber-500/60 bg-amber-500/8 px-1.5 py-0.5 rounded"
                                        >15m</span
                                    >
                                </div>
                            </div>
                            <div
                                class="flex items-center justify-between text-sm"
                            >
                                <div class="flex items-center gap-2">
                                    <span
                                        class="h-1.5 w-1.5 rounded-full bg-[#3a3a4a]"
                                    />
                                    <span class="text-muted-foreground"
                                        >RSI Reversal</span
                                    >
                                </div>
                                <div class="flex items-center gap-2">
                                    <span class="text-[#3a3a4a] text-xs"
                                        >XAU/USD</span
                                    >
                                    <span
                                        class="font-mono text-[10px] text-[#3a3a4a] bg-[#1a1a20] px-1.5 py-0.5 rounded"
                                        >1H</span
                                    >
                                </div>
                            </div>
                        </div>
                    </div>
                </aside>

                <!-- Chart Area -->
                <div
                    class="lg:col-span-3 fr-card overflow-hidden flex flex-col"
                >
                    <div
                        class="flex items-center justify-between border-b border-amber-500/8 px-4 py-2.5"
                    >
                        <div class="flex items-center gap-4">
                            <span class="text-sm font-semibold text-foreground"
                                >EUR/USD</span
                            >
                            <div class="flex gap-1">
                                <span
                                    v-for="tf in [
                                        '1m',
                                        '5m',
                                        '15m',
                                        '1H',
                                        '4H',
                                        'D',
                                    ]"
                                    :key="tf"
                                    class="text-[11px] cursor-pointer transition-colors px-2 py-0.5 rounded"
                                    :class="
                                        tf === '15m'
                                            ? 'text-amber-400 bg-primary/10'
                                            : 'text-[#4a4a5a] hover:text-[#c8c4bd]'
                                    "
                                    >{{ tf }}</span
                                >
                            </div>
                        </div>
                        <div
                            class="flex items-center gap-3 font-mono text-[10px]"
                        >
                            <span class="text-muted-foreground"
                                >O
                                <span class="text-[#c8c4bd]"
                                    >1.16653</span
                                ></span
                            >
                            <span class="text-muted-foreground"
                                >H
                                <span class="text-emerald-400"
                                    >1.16688</span
                                ></span
                            >
                            <span class="text-muted-foreground"
                                >L
                                <span class="text-red-400">1.16621</span></span
                            >
                            <span class="text-muted-foreground"
                                >C
                                <span class="text-[#c8c4bd]"
                                    >1.16670</span
                                ></span
                            >
                        </div>
                    </div>
                    <div
                        class="flex-1 flex items-center justify-center text-[#2a2a3a] text-sm"
                    >
                        Chart renders here
                    </div>
                    <!-- Status bar -->
                    <div
                        class="border-t border-amber-500/8 px-4 py-1.5 flex items-center justify-between text-[10px]"
                    >
                        <div class="flex items-center gap-3">
                            <span class="flex items-center gap-1.5">
                                <span
                                    class="h-1.5 w-1.5 rounded-full bg-emerald-500"
                                />
                                <span class="text-muted-foreground">Connected</span>
                            </span>
                            <span class="text-[#2a2a3a]">·</span>
                            <span class="text-muted-foreground">OANDA Practice</span>
                        </div>
                        <span class="font-mono text-[#3a3a4a]">{{
                            new Date().toLocaleTimeString()
                        }}</span>
                    </div>
                </div>
            </div>
        </div>
    </main>
</template>

<script setup lang="ts">
import { ref } from "vue";

const activeTheme = ref("forge");

const themes = [
    { id: "forge", label: "Forge" },
    { id: "terminal", label: "Terminal" },
    { id: "meridian", label: "Meridian" },
    { id: "forge-terminal", label: "Forge + Terminal" },
    { id: "forge-refined", label: "Forge Refined" },
];

const mockPrices = [
    {
        instrument: "EUR/USD",
        bid: "1.16653",
        ask: "1.16670",
        spread: "0.00017",
        time: "5:35 PM",
        selected: true,
    },
    {
        instrument: "USD/CAD",
        bid: "1.38496",
        ask: "1.38516",
        spread: "0.00020",
        time: "5:35 PM",
        selected: false,
    },
    {
        instrument: "GBP/USD",
        bid: "1.33952",
        ask: "1.33972",
        spread: "0.00020",
        time: "5:35 PM",
        selected: false,
    },
    {
        instrument: "USD/JPY",
        bid: "158.753",
        ask: "158.773",
        spread: "0.020",
        time: "5:35 PM",
        selected: false,
    },
    {
        instrument: "AUD/USD",
        bid: "0.70378",
        ask: "0.70393",
        spread: "0.00015",
        time: "5:35 PM",
        selected: false,
    },
    {
        instrument: "XAU/USD",
        bid: "4729.740",
        ask: "4730.640",
        spread: "0.900",
        time: "5:35 PM",
        selected: false,
    },
];
</script>

<style scoped>
/* ============================================
   FORGE — warm, refined, Carbon & Fire inspired
   ============================================ */
.forge-theme {
    --forge-bg: #0c0c10;
    --forge-card: #111116;
    --forge-border: rgba(217, 159, 67, 0.12);
    --forge-glow: rgba(217, 159, 67, 0.06);
}

.forge-card {
    background: linear-gradient(135deg, var(--forge-card) 0%, #0e0e14 100%);
    border: 1px solid var(--forge-border);
    border-radius: 10px;
    box-shadow:
        0 0 0 1px rgba(0, 0, 0, 0.3),
        inset 0 1px 0 rgba(255, 255, 255, 0.02),
        0 4px 24px rgba(0, 0, 0, 0.3);
}

.forge-card-interactive {
    background: linear-gradient(135deg, var(--forge-card) 0%, #0e0e14 100%);
    border: 1px solid rgba(217, 159, 67, 0.08);
    border-radius: 10px;
    box-shadow: 0 2px 12px rgba(0, 0, 0, 0.2);
    transition: all 0.2s ease;
}

.forge-card-interactive:hover {
    border-color: rgba(217, 159, 67, 0.25);
    box-shadow:
        0 2px 12px rgba(0, 0, 0, 0.2),
        0 0 20px var(--forge-glow);
}

.forge-card-selected {
    border-color: rgba(217, 159, 67, 0.35) !important;
    box-shadow:
        0 2px 12px rgba(0, 0, 0, 0.2),
        0 0 30px rgba(217, 159, 67, 0.08) !important;
}

/* ============================================
   TERMINAL — dense, utilitarian, Bloomberg-esque
   ============================================ */
.terminal-theme {
    --term-bg: #0a0a0a;
    --term-card: #0f0f0f;
}

.terminal-card {
    background: var(--term-card);
    border: 1px solid rgba(34, 197, 94, 0.08);
    border-radius: 4px;
}

/* ============================================
   MERIDIAN — cool, clean, modern
   ============================================ */
.meridian-theme {
    --mer-bg: #0b0d14;
    --mer-card: #0f1119;
}

.meridian-card {
    background: linear-gradient(160deg, var(--mer-card) 0%, #0d0f17 100%);
    border: 1px solid rgba(96, 165, 250, 0.08);
    border-radius: 12px;
    box-shadow: 0 4px 20px rgba(0, 0, 0, 0.25);
}

.meridian-card-interactive {
    background: linear-gradient(160deg, var(--mer-card) 0%, #0d0f17 100%);
    border: 1px solid rgba(96, 165, 250, 0.06);
    border-radius: 12px;
    box-shadow: 0 2px 12px rgba(0, 0, 0, 0.15);
    transition: all 0.2s ease;
}

.meridian-card-interactive:hover {
    border-color: rgba(96, 165, 250, 0.18);
    box-shadow: 0 2px 20px rgba(96, 165, 250, 0.05);
}

.meridian-card-selected {
    border-color: rgba(96, 165, 250, 0.25) !important;
    box-shadow: 0 2px 24px rgba(96, 165, 250, 0.08) !important;
}

/* ============================================
   FORGE + TERMINAL — warm monospace density
   ============================================ */
.ft-theme {
    --ft-bg: #0b0b0f;
    --ft-card: #0f0f14;
    --ft-border: rgba(217, 159, 67, 0.1);
    --ft-glow: rgba(217, 159, 67, 0.04);
}

.ft-card {
    background: linear-gradient(145deg, var(--ft-card) 0%, #0c0c11 100%);
    border: 1px solid var(--ft-border);
    border-radius: 6px;
    box-shadow:
        0 0 0 1px rgba(0, 0, 0, 0.4),
        inset 0 1px 0 rgba(255, 255, 255, 0.015),
        0 4px 16px rgba(0, 0, 0, 0.3);
}

.ft-row {
    border-bottom: 1px solid rgba(217, 159, 67, 0.04);
}

.ft-row:hover {
    background: rgba(217, 159, 67, 0.04);
}

.ft-row-selected {
    background: rgba(217, 159, 67, 0.07);
    border-bottom: 1px solid rgba(217, 159, 67, 0.08);
}

.ft-row-selected td:first-child {
    color: #d99f43;
}

/* ============================================
   FORGE REFINED — warm density, human labels
   ============================================ */
.fr-theme {
    --fr-bg: #0b0b0f;
    --fr-card: #0f0f14;
    --fr-border: rgba(217, 159, 67, 0.1);
}

.fr-card {
    background: linear-gradient(145deg, var(--fr-card) 0%, #0c0c11 100%);
    border: 1px solid var(--fr-border);
    border-radius: 8px;
    box-shadow:
        0 0 0 1px rgba(0, 0, 0, 0.4),
        inset 0 1px 0 rgba(255, 255, 255, 0.015),
        0 4px 16px rgba(0, 0, 0, 0.3);
}

.fr-section-label {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: rgba(217, 159, 67, 0.55);
    padding-bottom: 6px;
    border-bottom: 1px solid rgba(217, 159, 67, 0.1);
}

.fr-row {
    border-bottom: 1px solid rgba(217, 159, 67, 0.04);
}

.fr-row:hover {
    background: rgba(217, 159, 67, 0.04);
}

.fr-row-selected {
    background: rgba(217, 159, 67, 0.07);
    border-bottom: 1px solid rgba(217, 159, 67, 0.08);
}

.fr-row-selected td:first-child {
    color: #d99f43;
}
</style>
