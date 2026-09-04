import { createRouter, createWebHashHistory } from 'vue-router'
import { busyActive } from '../stores/busy'
import StatusView from '../views/StatusView.vue'
import StrategiesView from '../views/StrategiesView.vue'
import DomainsView from '../views/DomainsView.vue'
import SettingsView from '../views/SettingsView.vue'

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', name: 'status', component: StatusView },
    { path: '/strategies', name: 'strategies', component: StrategiesView },
    { path: '/domains/:list?', name: 'domains', component: DomainsView },
    { path: '/settings/:panel?', name: 'settings', component: SettingsView },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
})

// во время активной операции навигация запрещена — как switchView в старом app.js
router.beforeEach(() => !busyActive.value)
