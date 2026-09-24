import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The Tesla MCU2 browser is Chromium 79: no optional chaining, flex gap, `inset` or :is().
// JS/CSS are lowered to that floor so the page still works when opened in the car.
export default defineConfig({
  plugins: [react()],
  server: { host: '127.0.0.1' },
  build: { target: ['chrome79', 'safari14', 'firefox78'], cssTarget: ['chrome79', 'safari14'] },
});
