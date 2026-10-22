// Vercel Function (Node.js runtime, chữ ký Web Request/Response qua export GET/POST/OPTIONS):
// chạy cùng code webhook/zalo-webhook.js trên *.vercel.app. Lý do: Cloudflare (workers.dev /
// pages.dev) chặn request "Java/..." của máy chủ Zalo bằng Browser Integrity Check (lỗi 1010).
import { waitUntil } from '@vercel/functions';

import worker from '../webhook/zalo-webhook.js';

// Trả lời AI có thể mất 10–30 giây: cho phép hàm chạy tới 60 giây (xử lý nền sau khi đã trả 200 cho Zalo).
export const maxDuration = 60;

export function buildEnv() {
  return {
    // Chuyển toàn bộ biến môi trường (CRON_SECRET, PUBLIC_BASE_URL, TEAM_IDS...) cho webhook.
    ...process.env,
    FIREBASE_PROJECT_ID: process.env.FIREBASE_PROJECT_ID || 'pickleball-fund-phm',
    FIREBASE_API_KEY: process.env.FIREBASE_API_KEY || '',
    ZALO_SECRET: process.env.ZALO_SECRET || '',
    TEAM_ID: process.env.TEAM_ID || '',
    GEMINI_API_KEY: process.env.GEMINI_API_KEY || '',
    GEMINI_MODEL: process.env.GEMINI_MODEL || '',
    OPENAI_API_KEY: process.env.OPENAI_API_KEY || '',
    OPENAI_MODEL: process.env.OPENAI_MODEL || '',
    // Cho phép webhook trả lời Zalo ngay và tiếp tục gọi AI ở nền.
    waitUntil,
  };
}

export const GET = (request) => worker.fetch(request, buildEnv());
export const POST = (request) => worker.fetch(request, buildEnv());
export const OPTIONS = (request) => worker.fetch(request, buildEnv());
export const HEAD = (request) => worker.fetch(request, buildEnv());
