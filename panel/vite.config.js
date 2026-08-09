import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    // host: true libera o acesso pelo IP da rede local (util para testar
    // o painel de outro aparelho durante o desenvolvimento).
    host: true,
  },
});
