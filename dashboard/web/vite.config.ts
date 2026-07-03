import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      // In dev the Vite dev server proxies API calls to the Fastify server.
      "/api": "http://127.0.0.1:8088",
    },
  },
  build: {
    outDir: "dist",
    sourcemap: false,
  },
});
