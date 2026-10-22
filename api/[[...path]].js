// Vercel Edge Function: chạy cùng code Worker trên *.vercel.app.
// Lý do: Cloudflare (workers.dev / pages.dev) chặn request "Java/..." của máy chủ Zalo
// bằng Browser Integrity Check (lỗi 1010) và không tắt được trên tên miền *.dev.
import worker from '../worker/src/index.js';

export const config = { runtime: 'edge' };

export default function handler(request) {
  const env = {
    FIREBASE_PROJECT_ID: process.env.FIREBASE_PROJECT_ID || 'pickleball-fund-phm',
    FIREBASE_API_KEY: process.env.FIREBASE_API_KEY || '',
    ZALO_SECRET: process.env.ZALO_SECRET || '',
    TEAM_ID: process.env.TEAM_ID || '',
  };
  return worker.fetch(request, env);
}
