// Cloudflare Pages Functions: bọc lại Worker để chạy trên tên miền *.pages.dev
// (workers.dev bị Browser Integrity Check chặn request "Java/..." của máy chủ Zalo).
import worker from '../../worker/src/index.js';

export const onRequest = (context) => worker.fetch(context.request, context.env);
