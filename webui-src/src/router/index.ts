import { createRouter, createWebHashHistory } from 'vue-router'
import { busyActive } from '../stores/busy'
import { statusLoaded } from '../stores/status'
import StatusView from '../views/StatusView.vue'
import StrategiesView from '../views/StrategiesView.vue'
import DomainsView from '../views/DomainsView.vue'
import CustomStratsView from '../views/CustomStratsView.vue'
import CustomBlobsView from '../views/CustomBlobsView.vue'
import SettingsView from '../views/SettingsView.vue'

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', name: 'status', component: StatusView },
    { path: '/strategies', name: 'strategies', component: StrategiesView },
    { path: '/domains/:list?', name: 'domains', component: DomainsView },
    { path: '/custom-strats', name: 'custom-strats', component: CustomStratsView },
    { path: '/custom-blobs', name: 'custom-blobs', component: CustomBlobsView },
    { path: '/settings/:panel?', name: 'settings', component: SettingsView },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
})

// Первая (стартовая) навигация всегда разрешена — иначе диплинк не откроется.
// Дальше: во время операции и первичной загрузки переходы запрещены.
let firstNavigation = true
router.beforeEach(() => {
  if (firstNavigation) {
    firstNavigation = false
    return true
  }
  return !busyActive.value && statusLoaded.value
})
