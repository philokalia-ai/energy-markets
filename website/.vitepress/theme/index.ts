import DefaultTheme from 'vitepress/theme'
import type { Theme } from 'vitepress'
import { defineAsyncComponent } from 'vue'
import DatasetCard from '../components/DatasetCard.vue'
import ZoneSummaryTable from '../components/ZoneSummaryTable.vue'
import './style.css'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('DatasetCard', DatasetCard)
    app.component('ZoneSummaryTable', ZoneSummaryTable)
    // PriceChart uses ECharts which requires `document` — load client-only
    if (!import.meta.env.SSR) {
      app.component(
        'PriceChart',
        defineAsyncComponent(() => import('../components/PriceChart.vue'))
      )
    }
  },
} satisfies Theme
