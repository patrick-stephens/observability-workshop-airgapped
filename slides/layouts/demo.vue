<script setup lang="ts">
import DemoLayout from './DemoLayout.vue'

defineProps<{
  beat?: number
}>()
</script>

<template>
  <DemoLayout :beat="beat">
    <slot />
  </DemoLayout>
</template>
