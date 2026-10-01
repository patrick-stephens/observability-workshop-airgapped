<script setup lang="ts">
defineProps<{
  current: number
}>()

const beats = [
  'Baseline',
  'Latency',
  'Errors',
  'Alert lifecycle',
  'Torpedo',
  'DNS',
  'Traces',
  'Logs',
  'Perses',
  'Recovery',
]
</script>

<template>
  <nav class="beat-counter" aria-label="Demo sequence">
    <template v-for="(beat, index) in beats" :key="beat">
      <span class="beat-item" :class="{ 'is-current': index === current }">
        <span v-if="index === current" class="beat-marker" aria-hidden="true" />
        {{ beat }}
      </span>
      <span v-if="index < beats.length - 1" class="beat-connector" aria-hidden="true" />
    </template>
  </nav>
</template>

<style scoped>
.beat-counter {
  display: flex;
  align-items: center;
  width: min(100%, 1200px);
  color: #7d838c;
  font-family: 'JetBrains Mono', monospace;
  font-size: 11px;
  font-weight: 400;
  letter-spacing: 0.05em;
  line-height: 1;
  text-transform: uppercase;
  white-space: nowrap;
}

.beat-item {
  display: inline-flex;
  flex: 0 0 auto;
  align-items: center;
  gap: 6px;
  opacity: 0.55;
}

.beat-item.is-current {
  color: #ffb454;
  opacity: 1;
}

.beat-marker {
  width: 6px;
  height: 6px;
  background: currentColor;
}

.beat-connector {
  height: 1px;
  flex: 1 1 20px;
  min-width: 12px;
  margin: 0 9px;
  background: #454a51;
}
</style>
