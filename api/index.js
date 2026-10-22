// Đường dẫn gốc "/" của Vercel (catch-all [...path] không khớp "/"). Cùng cấu hình với api/[...path].js.
import { waitUntil } from '@vercel/functions';

import worker from '../webhook/zalo-webhook.js';

export const maxDuration = 60;

function buildEnv() {
  return {
    ...process.env,
    FIREBASE_PROJECT_ID: process.env.FIREBASE_PROJECT_ID || 'pickleball-fund-phm',
    FIREBASE_API_KEY: process.env.FIREBASE_API_KEY || '',
    ZALO_SECRET: process.env.ZALO_SECRET || '',
    TEAM_ID: process.env.TEAM_ID || '',
    GEMINI_API_KEY: process.env.GEMINI_API_KEY || '',
    GEMINI_MODEL: process.env.GEMINI_MODEL || '',
    OPENAI_API_KEY: process.env.OPENAI_API_KEY || '',
    OPENAI_MODEL: process.env.OPENAI_MODEL || '',
    waitUntil,
  };
}

export const GET = (request) => worker.fetch(request, buildEnv());
export const POST = (request) => worker.fetch(request, buildEnv());
export const OPTIONS = (request) => worker.fetch(request, buildEnv());
export const HEAD = (request) => worker.fetch(request, buildEnv());
