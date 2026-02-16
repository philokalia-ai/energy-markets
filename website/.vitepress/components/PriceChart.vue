<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { use } from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import { LineChart } from 'echarts/charts'
import {
  TitleComponent,
  TooltipComponent,
  LegendComponent,
  GridComponent,
  DataZoomComponent,
} from 'echarts/components'
import VChart from 'vue-echarts'

use([
  CanvasRenderer,
  LineChart,
  TitleComponent,
  TooltipComponent,
  LegendComponent,
  GridComponent,
  DataZoomComponent,
])

const props = defineProps<{
  zone?: string
  dataUrl?: string
}>()

interface PriceData {
  timestamps: string[]
  simulated: number[]
  actual: number[]
  zone: string
}

const data = ref<PriceData | null>(null)
const loading = ref(true)
const error = ref<string | null>(null)

onMounted(async () => {
  const url = props.dataUrl || '/data/sample-prices.json'
  try {
    const resp = await fetch(url)
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`)
    const json = await resp.json()
    // If multi-zone file, pick the requested zone
    if (props.zone && json[props.zone]) {
      data.value = json[props.zone]
    } else if (json.timestamps) {
      data.value = json as PriceData
    } else {
      // Take first zone
      const firstKey = Object.keys(json)[0]
      data.value = json[firstKey]
    }
  } catch (e: any) {
    error.value = e.message
  } finally {
    loading.value = false
  }
})

const chartOption = computed(() => {
  if (!data.value) return {}
  return {
    title: {
      text: `Day-Ahead Prices — ${data.value.zone || props.zone || 'GR'}`,
      left: 'center',
      textStyle: { fontSize: 14 },
    },
    tooltip: {
      trigger: 'axis',
      valueFormatter: (v: number) => `${v.toFixed(1)} EUR/MWh`,
    },
    legend: {
      bottom: 0,
      data: ['Simulated', 'Actual'],
    },
    grid: {
      left: 60,
      right: 30,
      top: 50,
      bottom: 60,
    },
    xAxis: {
      type: 'category',
      data: data.value.timestamps,
      axisLabel: { rotate: 45, fontSize: 10 },
    },
    yAxis: {
      type: 'value',
      name: 'EUR/MWh',
      nameLocation: 'middle',
      nameGap: 45,
    },
    dataZoom: [
      { type: 'inside', start: 0, end: 100 },
      { type: 'slider', start: 0, end: 100, bottom: 30 },
    ],
    series: [
      {
        name: 'Simulated',
        type: 'line',
        data: data.value.simulated,
        lineStyle: { width: 1.5 },
        symbol: 'none',
        color: '#3b82f6',
      },
      {
        name: 'Actual',
        type: 'line',
        data: data.value.actual,
        lineStyle: { width: 1.5, type: 'dashed' },
        symbol: 'none',
        color: '#f97316',
      },
    ],
  }
})
</script>

<template>
  <div class="price-chart-wrapper">
    <div v-if="loading" class="chart-placeholder">Loading chart data...</div>
    <div v-else-if="error" class="chart-placeholder chart-error">
      Could not load price data: {{ error }}
    </div>
    <VChart v-else :option="chartOption" autoresize style="height: 400px" />
  </div>
</template>

<style scoped>
.price-chart-wrapper {
  margin: 1.5rem 0;
}

.chart-placeholder {
  height: 400px;
  display: flex;
  align-items: center;
  justify-content: center;
  border: 1px dashed var(--vp-c-divider);
  border-radius: 8px;
  color: var(--vp-c-text-3);
  font-style: italic;
}

.chart-error {
  color: var(--vp-c-danger-1);
}
</style>
