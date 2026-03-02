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
 * Health and status endpoints are always unauthenticated (Cloudron requirement).
 */

'use strict';

const http = require('http');
const { spawn, execFile, execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = 3000;
const WORKSPACE = '/app/data/workspace';
const LOGS_DIR = '/app/data/logs';
const CONFIG_FILE = '/app/data/config/worker.json';
const VERSION = '0.1.0';

// ============================================
// Input validation
// ============================================

/** Validate repo slug: must be exactly "owner/repo" with safe characters. */
function isValidRepo(repo) {
  return typeof repo === 'string' && /^[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+$/.test(repo);
}

/** Validate task ID: alphanumeric, dashes, dots only. */
function isValidTaskId(taskId) {
  return typeof taskId === 'string' && /^[a-zA-Z0-9._-]+$/.test(taskId) && taskId.length <= 128;
}

/** Validate branch name: git-safe characters, no shell metacharacters. */
function isValidBranch(branch) {
  return typeof branch === 'string' && /^[a-zA-Z0-9._\/-]+$/.test(branch)
    && !branch.includes('..') && branch.length <= 256;
}

/** Escape HTML to prevent XSS in dashboard rendering. */
function escapeHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

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
  if (!token) {
    // No token = reject all mutating requests (secure by default)
    console.warn('[auth] No auth_token configured — rejecting request. Set dispatch.auth_token in worker.json.');
    return false;
  }
  const authHeader = req.headers.authorization || '';
  const provided = authHeader.replace(/^Bearer\s+/i, '');
  // Constant-time comparison to prevent timing attacks
  if (provided.length !== token.length) return false;
  return crypto.timingSafeEqual(Buffer.from(provided), Buffer.from(token));
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
// Safe git operations (no shell interpolation)
// ============================================

/** Run git command with arguments as array (no shell). Returns promise. */
function gitExec(args, options = {}) {
  return new Promise((resolve, reject) => {
    execFile('git', args, { encoding: 'utf8', timeout: 120000, ...options }, (err, stdout, stderr) => {
      if (err) {
        err.stderr = stderr;
        reject(err);
      } else {
        resolve(stdout);
      }
    });
  });
}

// ============================================
// Dashboard HTML
// ============================================

function renderDashboard(status) {
  const workerRows = [];
  for (const [taskId, info] of workers) {
    const elapsed = Math.floor((Date.now() - new Date(info.startTime).getTime()) / 60000);
    const safeTaskId = escapeHtml(taskId);
    const safeRepo = escapeHtml(info.repo);
    workerRows.push(
      `<tr><td><code>${safeTaskId}</code></td><td>${safeRepo}</td><td>${elapsed}m</td>` +
      `<td><a href="/workers/${encodeURIComponent(taskId)}/logs">logs</a></td></tr>`
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
  <h1>AI DevOps Worker <span class="badge">${escapeHtml(status.status)}</span></h1>
  <p class="meta">v${escapeHtml(status.version)} | up ${Math.floor(status.uptime_seconds / 60)}m |
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
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 1048576) { // 1MB limit
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
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

  // Validate all inputs before any use
  if (!repo || !prompt) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'repo and prompt are required' }));
    return;
  }

  if (!isValidRepo(repo)) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'invalid repo format — must be owner/repo' }));
    return;
  }

  if (body.task_id && !isValidTaskId(body.task_id)) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'invalid task_id — alphanumeric, dashes, dots only' }));
    return;
  }

  if (branch && !isValidBranch(branch)) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'invalid branch name' }));
    return;
  }

  if (typeof prompt !== 'string' || prompt.length > 10000) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'prompt must be a string under 10000 chars' }));
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

  // Build safe paths — repo is validated, so replace is safe
  const repoDir = path.join(WORKSPACE, repo.replace('/', '-'));
  const logFile = path.join(LOGS_DIR, `${taskId}.log`);

  // Verify resolved paths stay within expected directories (defense in depth)
  if (!path.resolve(repoDir).startsWith(path.resolve(WORKSPACE))) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'path traversal detected' }));
    return;
  }
  if (!path.resolve(logFile).startsWith(path.resolve(LOGS_DIR))) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'path traversal detected' }));
    return;
  }

  try {
    fs.mkdirSync(LOGS_DIR, { recursive: true });

    // Use execFile (no shell) for all git operations
    if (!fs.existsSync(repoDir)) {
      console.log(`[dispatch] Cloning ${repo}`);
      await gitExec(['clone', '--depth=50', `https://github.com/${repo}.git`, repoDir]);
    } else {
      console.log(`[dispatch] Updating ${repoDir}`);
      await gitExec(['fetch', 'origin'], { cwd: repoDir });
      await gitExec(['checkout', 'main'], { cwd: repoDir });
      await gitExec(['reset', '--hard', 'origin/main'], { cwd: repoDir });
    }

    if (branch && branch !== 'main') {
      try {
        await gitExec(['checkout', '-B', branch, `origin/${branch}`], { cwd: repoDir });
      } catch {
        await gitExec(['checkout', '-b', branch], { cwd: repoDir });
      }
    }
  } catch (err) {
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'repo setup failed', details: err.message }));
    return;
  }

  // Spawn headless worker — prompt passed as argument (no shell)
  console.log(`[dispatch] Starting worker ${taskId} in ${repoDir}`);
  const logStream = fs.createWriteStream(logFile, { flags: 'a' });

  const env = {
    ...process.env,
    HOME: '/home/cloudron',
    FULL_LOOP_HEADLESS: 'true',
    AIDEVOPS_REMOTE_DISPATCH: 'true',
  };
  if (model && typeof model === 'string' && /^[a-zA-Z0-9./_-]+$/.test(model)) {
    env.ANTHROPIC_MODEL = model;
  }

  // Use claude CLI (installed globally) — spawn with array args, no shell
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
  if (!isValidTaskId(taskId)) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'invalid task_id' }));
    return;
  }
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
  if (!isValidTaskId(taskId)) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'invalid task_id' }));
    return;
  }
  const logFile = path.join(LOGS_DIR, `${taskId}.log`);
  // Defense in depth: verify resolved path stays within LOGS_DIR
  if (!path.resolve(logFile).startsWith(path.resolve(LOGS_DIR))) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'path traversal detected' }));
    return;
  }
  if (!fs.existsSync(logFile)) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'log not found' }));
    return;
  }
  try {
    // Use execFile with args array — no shell interpolation
    const { execFileSync } = require('child_process');
    const content = execFileSync('tail', ['-500', logFile], { encoding: 'utf8', timeout: 5000 });
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
    handleCancel(res, decodeURIComponent(workerMatch[1]));
    return;
  }

  const logsMatch = url.pathname.match(/^\/workers\/([^/]+)\/logs$/);
  if (logsMatch && req.method === 'GET') {
    handleLogs(res, decodeURIComponent(logsMatch[1]));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[aidevops-worker] Listening on port ${PORT}`);
});
