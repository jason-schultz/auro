<template>
    <main class="p-6">
        <ViewHeader title="Dashboard" />

        <SystemPulseStrip />

        <!-- Everything Auro manages, at a glance -->
        <PortfolioStrip />

        <!-- What's working: equity trend + per-strategy scoreboard -->
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-4 mb-4">
            <div class="lg:col-span-2 min-h-0">
                <EquityCurvePanel />
            </div>
            <div class="lg:col-span-1 min-h-0">
                <StrategyLeaderboardPanel />
            </div>
        </div>

        <!-- Live risk -->
        <div class="mb-4">
            <OpenPositionsPanel />
        </div>

        <div class="mb-4">
            <PerformanceKpisPanel />
        </div>

        <!-- Activity -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-4">
            <AlgoActivityPanel />
            <SignalFeedPanel />
        </div>

        <!-- Engine context -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <RulesStatePanel />
            <RegimeHeatmapPanel />
        </div>
    </main>
</template>

<script setup lang="ts">
import AlgoActivityPanel from "@/components/dashboard/AlgoActivityPanel.vue";
import EquityCurvePanel from "@/components/dashboard/EquityCurvePanel.vue";
import OpenPositionsPanel from "@/components/dashboard/OpenPositionsPanel.vue";
import PerformanceKpisPanel from "@/components/dashboard/PerformanceKpisPanel.vue";
import PortfolioStrip from "@/components/dashboard/PortfolioStrip.vue";
import RegimeHeatmapPanel from "@/components/dashboard/RegimeHeatmapPanel.vue";
import RulesStatePanel from "@/components/dashboard/RulesStatePanel.vue";
import SignalFeedPanel from "@/components/dashboard/SignalFeedPanel.vue";
import StrategyLeaderboardPanel from "@/components/dashboard/StrategyLeaderboardPanel.vue";
import SystemPulseStrip from "@/components/dashboard/SystemPulseStrip.vue";
import ViewHeader from "@/components/ui/ViewHeader.vue";
</script>
