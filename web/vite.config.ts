import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  base: '/app/',
  plugins: [react()],
  server: {
    proxy: {
      '/enroll': 'http://127.0.0.1:8080',
      '/me': 'http://127.0.0.1:8080',
      '/captures': 'http://127.0.0.1:8080',
    },
  },
})
