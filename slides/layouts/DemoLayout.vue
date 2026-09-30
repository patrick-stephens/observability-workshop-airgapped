<script setup lang="ts">
import BeatCounter from '../components/BeatCounter.vue'

defineProps<{
  beat?: number
}>()
</script>

<template>
  <div class="slidev-layout demo-layout">
    <main class="demo-title">
      <slot />
    </main>
    <footer v-if="beat !== undefined" class="demo-footer">
      <BeatCounter :current="Number(beat)" />
    </footer>
  </div>
</template>
