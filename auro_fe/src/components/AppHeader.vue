<template>
    <header class="border-b border-amber-500/8 px-6 py-4">
        <div class="flex items-center justify-between">
            <div class="flex items-center gap-8">
                <router-link
                    to="/"
                    class="text-xl font-bold tracking-tight text-foreground"
                >
                    Auro
                </router-link>

                <nav class="flex items-center gap-1">
                    <router-link
                        v-for="link in navLinks"
                        :key="link.to"
                        :to="link.to"
                        class="px-3 py-1.5 text-sm rounded transition-colors"
                        :class="
                            isActive(link.to)
                                ? 'bg-primary/10 text-amber-400'
                                : 'text-[#7a7a8a] hover:text-foreground'
                        "
                    >
                        {{ link.label }}
                    </router-link>
                </nav>
            </div>

            <div class="flex items-center gap-3">
                <span class="flex items-center gap-1.5">
                    <span
                        class="h-1.5 w-1.5 rounded-full bg-emerald-500 animate-pulse"
                    />
                    <span class="text-[10px] text-muted-foreground"
                        >Connected</span
                    >
                </span>
                <span class="text-[10px] text-[#3a3a4a]">·</span>
                <span class="text-[10px] text-muted-foreground font-mono"
                    >Paper Trading</span
                >
            </div>
        </div>
    </header>
</template>

<script setup lang="ts">
import { useRoute } from "vue-router";

const route = useRoute();

const navLinks = [
    { to: "/", label: "Dashboard" },
    { to: "/markets", label: "Markets" },
    { to: "/strategies", label: "Strategies" },
    { to: "/backtests", label: "Backtests" },
    { to: "/journal", label: "Journal" },
];

function isActive(path: string): boolean {
    if (path === "/") return route.path === "/";
    return route.path.startsWith(path);
}
</script>
