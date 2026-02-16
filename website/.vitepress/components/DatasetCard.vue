<script setup lang="ts">
defineProps<{
  name: string
  description: string
  format?: string
  size?: string
  rows?: string
  downloadUrl?: string
}>()
</script>

<template>
  <div class="dataset-card">
    <h3>{{ name }}</h3>
    <p>{{ description }}</p>
    <div class="meta">
      <span v-if="format" class="badge">{{ format }}</span>
      <span v-if="size" class="badge">{{ size }}</span>
      <span v-if="rows" class="badge">{{ rows }} rows</span>
    </div>
    <a v-if="downloadUrl" :href="downloadUrl" class="download-link" download>
      Download
    </a>
    <span v-else class="download-link disabled">Run Julia export to generate</span>
  </div>
</template>

<style scoped>
.dataset-card {
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  padding: 1.25rem;
  background: var(--vp-c-bg-soft);
}

.dataset-card h3 {
  margin: 0 0 0.5rem;
  font-size: 1rem;
}

.dataset-card p {
  margin: 0 0 0.75rem;
  font-size: 0.875rem;
  color: var(--vp-c-text-2);
}

.meta {
  display: flex;
  gap: 0.5rem;
  flex-wrap: wrap;
  margin-bottom: 0.75rem;
}

.badge {
  font-size: 0.75rem;
  padding: 0.15rem 0.5rem;
  border-radius: 4px;
  background: var(--vp-c-bg-mute);
  color: var(--vp-c-text-2);
}

.download-link {
  font-size: 0.875rem;
  color: var(--vp-c-brand-1);
  text-decoration: none;
  font-weight: 500;
}

.download-link:hover {
  text-decoration: underline;
}

.download-link.disabled {
  color: var(--vp-c-text-3);
  cursor: default;
  font-style: italic;
}
</style>
