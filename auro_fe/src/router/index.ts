import { createRouter, createWebHistory } from "vue-router";
import Dashboard from "@/views/Dashboard.vue";

const routes = [
  {
    path: "/",
    name: "dashboard",
    component: Dashboard,
  },
  {
    path: "/markets",
    name: "markets",
    component: () => import("@/views/Markets.vue"),
  },
  {
    path: "/strategies",
    name: "strategies",
    component: () => import("@/views/Strategies.vue"),
  },
  {
    path: "/journal",
    name: "journal",
    component: () => import("@/views/Journal.vue"),
  },
  {
    path: "/backtests",
    name: "backtests",
    component: () => import("@/views/Backtests.vue"),
  },
  {
    path: "/live-trades/:id",
    name: "trade-detail",
    component: () => import("@/views/TradeDetail.vue"),
  },
];

const router = createRouter({
  history: createWebHistory(),
  routes,
});

export default router;
