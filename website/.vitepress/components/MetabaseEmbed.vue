<script setup>
import { ref, computed } from 'vue'

const props = defineProps({
  src: { type: String, required: true },
  height: { type: Number, default: 600 },
  title: { type: String, default: 'Metabase chart' }
})

const loaded = ref(false)

const isPlaceholder = computed(() =>
  !props.src || props.src.includes('UUID-HERE') || props.src.includes('METABASE_URL_PLACEHOLDER')
)
</script>

<template>
  <div class="metabase-embed">
    <div v-if="isPlaceholder" class="placeholder">
      <p>Metabase chart not yet configured.</p>
      <p class="hint">
        Enable public sharing in Metabase, then update the embed URL in
        <code>.vitepress/metabase.config.ts</code>.
      </p>
    </div>
    <template v-else>
      <div v-if="!loaded" class="loading">Loading chart...</div>
      <iframe
        :src="props.src"
        :title="props.title"
        :style="{ height: props.height + 'px' }"
        frameborder="0"
        allowtransparency
        @load="loaded = true"
      />
    </template>
  </div>
</template>

<style scoped>
.metabase-embed {
  margin: 1.5rem 0;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  overflow: hidden;
}

.metabase-embed iframe {
  width: 100%;
  border: none;
  display: block;
}

.placeholder {
  padding: 2rem;
  text-align: center;
  color: var(--vp-c-text-2);
  background: var(--vp-c-bg-soft);
}

.placeholder .hint {
  font-size: 0.85rem;
  margin-top: 0.5rem;
}

.placeholder code {
  font-size: 0.8rem;
  background: var(--vp-c-bg-mute);
  padding: 0.15rem 0.4rem;
  border-radius: 4px;
}

.loading {
  padding: 2rem;
  text-align: center;
  color: var(--vp-c-text-3);
}
</style>
