// Vercel Function (Node.js runtime, chữ ký Web Request/Response qua export GET/POST/OPTIONS):
// chạy cùng code Worker trên *.vercel.app. Lý do: Cloudflare (workers.dev / pages.dev) chặn
// request "Java/..." của máy chủ Zalo bằng Browser Integrity Check (lỗi 1010), không tắt được.
import worker from '../webhook/zalo-webhook.js';

function env() {
  return {
    FIREBASE_PROJECT_ID: process.env.FIREBASE_PROJECT_ID || 'pickleball-fund-phm',
    FIREBASE_API_KEY: process.env.FIREBASE_API_KEY || '',
    ZALO_SECRET: process.env.ZALO_SECRET || '',
    TEAM_ID: process.env.TEAM_ID || '',
  };
}

export const GET = (request) => worker.fetch(request, env());
export const POST = (request) => worker.fetch(request, env());
export const OPTIONS = (request) => worker.fetch(request, env());
export const HEAD = (request) => worker.fetch(request, env());
