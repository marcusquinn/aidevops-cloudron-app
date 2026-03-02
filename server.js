#!/usr/bin/env node

/**
 * AI DevOps Worker — unified HTTP server.
 *
 * Single process handling:
 * - /health          — Cloudron health check
 * - /status          — Detailed worker status (JSON)
 * - /                — Browser dashboard
 * - /dispatch        — Accept task dispatches
 * - /workers         — List/cancel active workers
 * - /workers/:id/logs — Stream worker logs
 *
 * Authentication: Bearer token from worker.json dispatch.auth_token.
 * If auth_token is empty, all mutating endpoints are open (development mode).
 * Health and status endpoints are always unauthenticated (Cloudron requirement).
 */

'use strict';

const http = require('http');
const { spawn, execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = 3000;
const WORKSPACE = '/app/data/workspace';
const LOGS_DIR = '/app/data/logs';
const CONFIG_FILE = '/app/data/config/worker.json';
const VERSION = '0.1.0';

// ============================================
// Active worker tracking
// ============================================

/** @type {Map<string, {process: ChildProcess, repo: string, taskId: string, startTime: string, logFile: string, pid: number}>} */
const workers = new Map();

// ============================================
// Config and system helpers
// ============================================

function readConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
  } catch {
    return { worker: {}, dispatch: {}, pulse: {} };
  }
}

function checkAuth(req) {
  const config = readConfig();
  const token = config.dispatch?.auth_token;
  if (!token) return true; // dev mode
  const authHeader = req.headers.authorization || '';
  return authHeader.replace(/^Bearer\s+/i, '') === token;
}

function countWorkers() {
  try {
    const output = execSync(
      "ps axo command 2>/dev/null | grep '/full-loop' | grep -v grep | wc -l",
      { encoding: 'utf8', timeout: 5000 }
    ).trim();
    return parseInt(output, 10) || 0;
  } catch {
    return workers.size; // fallback to in-memory count
  }
}

function getMemoryInfo() {
  try {
    const meminfo = fs.readFileSync('/proc/meminfo', 'utf8');
    const total = parseInt(meminfo.match(/MemTotal:\s+(\d+)/)?.[1] || '0', 10);
    const available = parseInt(meminfo.match(/MemAvailable:\s+(\d+)/)?.[1] || '0', 10);
    return { total_mb: Math.round(total / 1024), available_mb: Math.round(available / 1024) };
  } catch {
    return { total_mb: 0, available_mb: 0 };
  }
}

function getStatus() {
  const config = readConfig();
  const activeWorkers = countWorkers();
  const memory = getMemoryInfo();
  const maxWorkers = config.worker?.max_concurrent || 1;

  return {
    status: 'ok',
    version: VERSION,
    uptime_seconds: Math.floor(process.uptime()),
    workers: {
      active: activeWorkers,
      max: maxWorkers,
      available: Math.max(0, maxWorkers - activeWorkers),
    },
    memory,
    pulse: { enabled: config.pulse?.enabled || false },
  };
}

// ============================================
// Dashboard HTML
// ============================================

function renderDashboard(status) {
  const workerRows = [];
  for (const [taskId, info] of workers) {
    const elapsed = Math.floor((Date.now() - new Date(info.startTime).getTime()) / 60000);
    workerRows.push(
      `<tr><td><code>${taskId}</code></td><td>${info.repo}</td><td>${elapsed}m</td>` +
      `<td><a href="/workers/${taskId}/logs">logs</a></td></tr>`
    );
  }

  const workerTable = workerRows.length > 0
    ? `<table><tr><th>Task</th><th>Repo</th><th>Elapsed</th><th></th></tr>${workerRows.join('')}</table>`
    : '<p>No active workers</p>';

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>AI DevOps Worker</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
           max-width: 720px; margin: 40px auto; padding: 0 20px; color: #333; background: #fafafa; }
    h1 { border-bottom: 2px solid #0066cc; padding-bottom: 8px; }
    h2 { color: #555; font-size: 16px; margin-top: 28px; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 4px;
             background: #28a745; color: white; font-size: 13px; vertical-align: middle; }
    table { width: 100%; border-collapse: collapse; margin: 12px 0; }
    th { text-align: left; padding: 6px 12px; border-bottom: 2px solid #ddd; font-size: 13px; color: #666; }
    td { padding: 8px 12px; border-bottom: 1px solid #eee; }
    code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; font-size: 13px; }
    a { color: #0066cc; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .api-section code { display: inline-block; min-width: 200px; }
    .meta { color: #888; font-size: 13px; }
  </style>
  <meta http-equiv="refresh" content="30">
</head>
<body>
  <h1>AI DevOps Worker <span class="badge">${status.status}</span></h1>
  <p class="meta">v${status.version} | up ${Math.floor(status.uptime_seconds / 60)}m |
     ${status.memory.available_mb}MB free / ${status.memory.total_mb}MB total |
     pulse: ${status.pulse.enabled ? 'on' : 'off'}</p>

  <h2>Workers (${status.workers.active} / ${status.workers.max})</h2>
  ${workerTable}

  <h2>API</h2>
  <div class="api-section">
    <table>
      <tr><td><code>GET  /health</code></td><td>Health check</td></tr>
      <tr><td><code>GET  /status</code></td><td>Detailed status (JSON)</td></tr>
      <tr><td><code>POST /dispatch</code></td><td>Dispatch a task</td></tr>
      <tr><td><code>GET  /workers</code></td><td>List active workers</td></tr>
      <tr><td><code>DELETE /workers/:id</code></td><td>Cancel a worker</td></tr>
      <tr><td><code>GET  /workers/:id/logs</code></td><td>Worker logs</td></tr>
    </table>
  </div>
</body>
</html>`;
}

// ============================================
// Request body parser
// ============================================

function parseBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString())); }
      catch (err) { reject(err); }
    });
    req.on('error', reject);
  });
}

// ============================================
// Dispatch handler
// ============================================

async function handleDispatch(req, res) {
  let body;
  try {
    body = await parseBody(req);
  } catch {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'invalid JSON body' }));
    return;
  }

  const { repo, prompt, model, branch } = body;
  const taskId = body.task_id || `dispatch-${crypto.randomBytes(4).toString('hex')}`;

  if (!repo || !prompt) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'repo and prompt are required' }));
    return;
  }

  const config = readConfig();
  const maxWorkers = config.worker?.max_concurrent || 1;
  if (workers.size >= maxWorkers) {
    res.writeHead(429, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'at capacity', active: workers.size, max: maxWorkers }));
    return;
  }

  if (workers.has(taskId)) {
    res.writeHead(409, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'task already running', task_id: taskId }));
    return;
  }

  // Check allowed repos
  const allowedRepos = config.dispatch?.allowed_repos || [];
  if (allowedRepos.length > 0 && !allowedRepos.includes(repo)) {
    res.writeHead(403, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'repo not in allowed list', repo }));
    return;
  }

  // Clone or update repo
  const repoDir = path.join(WORKSPACE, repo.replace('/', '-'));
  const logFile = path.join(LOGS_DIR, `${taskId}.log`);

  try {
    fs.mkdirSync(LOGS_DIR, { recursive: true });

    if (!fs.existsSync(repoDir)) {
      console.log(`[dispatch] Cloning ${repo}`);
      execSync(
        `git clone --depth=50 "https://github.com/${repo}.git" "${repoDir}"`,
        { encoding: 'utf8', timeout: 120000 }
      );
    } else {
      console.log(`[dispatch] Updating ${repoDir}`);
      execSync('git fetch origin && git checkout main && git reset --hard origin/main', {
        cwd: repoDir, encoding: 'utf8', timeout: 60000,
      });
    }

    if (branch && branch !== 'main') {
      execSync(
        `git checkout -B "${branch}" "origin/${branch}" 2>/dev/null || git checkout -b "${branch}"`,
        { cwd: repoDir, encoding: 'utf8', timeout: 10000 }
      );
    }
  } catch (err) {
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'repo setup failed', details: err.message }));
    return;
  }

  // Spawn headless worker
  console.log(`[dispatch] Starting worker ${taskId} in ${repoDir}`);
  const logStream = fs.createWriteStream(logFile, { flags: 'a' });

  const env = {
    ...process.env,
    HOME: '/home/cloudron',
    FULL_LOOP_HEADLESS: 'true',
    AIDEVOPS_REMOTE_DISPATCH: 'true',
  };
  if (model) env.ANTHROPIC_MODEL = model;

  // Use claude CLI (installed globally)
  const workerProcess = spawn('claude', ['-p', prompt, '--allowedTools', '*'], {
    cwd: repoDir,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  workerProcess.stdout.pipe(logStream);
  workerProcess.stderr.pipe(logStream);

  workers.set(taskId, {
    process: workerProcess,
    repo,
    taskId,
    startTime: new Date().toISOString(),
    logFile,
    pid: workerProcess.pid,
  });

  workerProcess.on('close', (code) => {
    console.log(`[dispatch] Worker ${taskId} exited: ${code}`);
    logStream.end(`\n[EXIT:${code}] ${new Date().toISOString()}\n`);
    workers.delete(taskId);
  });

  workerProcess.on('error', (err) => {
    console.error(`[dispatch] Worker ${taskId} error: ${err.message}`);
    logStream.end(`\n[ERROR] ${err.message}\n`);
    workers.delete(taskId);
  });

  res.writeHead(202, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ task_id: taskId, status: 'dispatched', pid: workerProcess.pid, repo }));
}

// ============================================
// Worker management handlers
// ============================================

function handleListWorkers(res) {
  const list = [];
  for (const [taskId, info] of workers) {
    list.push({
      task_id: taskId,
      repo: info.repo,
      pid: info.pid,
      start_time: info.startTime,
      elapsed_minutes: Math.floor((Date.now() - new Date(info.startTime).getTime()) / 60000),
    });
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ workers: list }));
}

function handleCancel(res, taskId) {
  const worker = workers.get(taskId);
  if (!worker) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'worker not found' }));
    return;
  }
  worker.process.kill('SIGTERM');
  setTimeout(() => { if (!worker.process.killed) worker.process.kill('SIGKILL'); }, 10000);
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ status: 'cancelling', task_id: taskId }));
}

function handleLogs(res, taskId) {
  const logFile = path.join(LOGS_DIR, `${taskId}.log`);
  if (!fs.existsSync(logFile)) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'log not found' }));
    return;
  }
  try {
    const content = execSync(`tail -500 "${logFile}"`, { encoding: 'utf8', timeout: 5000 });
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(content);
  } catch {
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'failed to read log' }));
  }
}

// ============================================
// HTTP server
// ============================================

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  // Unauthenticated endpoints (Cloudron health check must be open)
  if (url.pathname === '/health' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  if (url.pathname === '/status' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(getStatus(), null, 2));
    return;
  }

  if (url.pathname === '/' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(renderDashboard(getStatus()));
    return;
  }

  // Authenticated endpoints
  if (!checkAuth(req)) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'unauthorized' }));
    return;
  }

  if (url.pathname === '/dispatch' && req.method === 'POST') {
    await handleDispatch(req, res);
    return;
  }

  if (url.pathname === '/workers' && req.method === 'GET') {
    handleListWorkers(res);
    return;
  }

  const workerMatch = url.pathname.match(/^\/workers\/([^/]+)$/);
  if (workerMatch && req.method === 'DELETE') {
    handleCancel(res, workerMatch[1]);
    return;
  }

  const logsMatch = url.pathname.match(/^\/workers\/([^/]+)\/logs$/);
  if (logsMatch && req.method === 'GET') {
    handleLogs(res, logsMatch[1]);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[aidevops-worker] Listening on port ${PORT}`);
});
