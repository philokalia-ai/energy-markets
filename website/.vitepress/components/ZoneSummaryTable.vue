<script setup lang="ts">
import { ref, computed } from 'vue'

interface ZoneMetrics {
  zone: string
  mae: number
  rmse: number
  mape: number
  correlation: number
  bias: number
  periods: number
}

const props = defineProps<{
  data?: ZoneMetrics[]
}>()

const defaultData: ZoneMetrics[] = [
  { zone: 'GR', mae: 18.2, rmse: 24.7, mape: 22.1, correlation: 0.82, bias: -3.4, periods: 35040 },
  { zone: 'BG', mae: 15.6, rmse: 21.3, mape: 19.8, correlation: 0.85, bias: -1.2, periods: 8760 },
  { zone: 'RO', mae: 16.9, rmse: 23.1, mape: 21.5, correlation: 0.83, bias: -2.8, periods: 8760 },
  { zone: 'HU', mae: 14.3, rmse: 19.8, mape: 17.6, correlation: 0.87, bias: -0.9, periods: 8760 },
  { zone: 'RS', mae: 17.5, rmse: 24.2, mape: 23.4, correlation: 0.80, bias: -4.1, periods: 8760 },
  { zone: 'HR', mae: 13.8, rmse: 18.9, mape: 16.2, correlation: 0.88, bias: 0.5, periods: 8760 },
]

const metrics = computed(() => props.data || defaultData)

const sortKey = ref<keyof ZoneMetrics>('zone')
const sortAsc = ref(true)

function sort(key: keyof ZoneMetrics) {
  if (sortKey.value === key) {
    sortAsc.value = !sortAsc.value
  } else {
    sortKey.value = key
    sortAsc.value = true
  }
}

const sorted = computed(() => {
  const items = [...metrics.value]
  items.sort((a, b) => {
    const av = a[sortKey.value]
    const bv = b[sortKey.value]
    if (typeof av === 'string' && typeof bv === 'string') {
      return sortAsc.value ? av.localeCompare(bv) : bv.localeCompare(av)
    }
    return sortAsc.value ? (av as number) - (bv as number) : (bv as number) - (av as number)
  })
  return items
})

function sortIcon(key: keyof ZoneMetrics) {
  if (sortKey.value !== key) return ''
  return sortAsc.value ? ' ▲' : ' ▼'
}
</script>

<template>
  <table class="zone-table">
    <thead>
      <tr>
        <th @click="sort('zone')">Zone{{ sortIcon('zone') }}</th>
        <th @click="sort('mae')">MAE{{ sortIcon('mae') }}</th>
        <th @click="sort('rmse')">RMSE{{ sortIcon('rmse') }}</th>
        <th @click="sort('mape')">MAPE (%){{ sortIcon('mape') }}</th>
        <th @click="sort('correlation')">Correlation{{ sortIcon('correlation') }}</th>
        <th @click="sort('bias')">Bias{{ sortIcon('bias') }}</th>
        <th @click="sort('periods')">Periods{{ sortIcon('periods') }}</th>
      </tr>
    </thead>
    <tbody>
      <tr v-for="row in sorted" :key="row.zone">
        <td>{{ row.zone }}</td>
        <td>{{ row.mae.toFixed(1) }}</td>
        <td>{{ row.rmse.toFixed(1) }}</td>
        <td>{{ row.mape.toFixed(1) }}</td>
        <td>{{ row.correlation.toFixed(2) }}</td>
        <td>{{ row.bias.toFixed(1) }}</td>
        <td>{{ row.periods.toLocaleString() }}</td>
      </tr>
    </tbody>
  </table>
</template>
