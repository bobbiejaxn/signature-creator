#!/usr/bin/env bun
/**
 * hermes-coms-bridge.ts
 *
 * Bridge between the coms-net hub and Hermes (Hermes Agent on VPS, Nous Research).
 * Connects via SSE to receive messages in real-time.
 *
 * Architecture:
 *   coms-net hub ←SSE→ this bridge → SSH → NetCup (prod)
 *
 * Commands handled directly (no Hermes needed):
 *   health [project]  — Docker container status on NetCup
 *   deploy <project>   — git pull + docker-compose up on NetCup
 *   logs <project> [N] — Tail container logs on NetCup
 *   status             — All containers on NetCup
 *   disk               — Disk usage on NetCup
 *   restart <project>  — Restart a project's containers
 *   rollback <project> — git reset --hard HEAD~1 + rebuild on NetCup
 *   backup             — Check last backup status (when, size, age) on NetCup
 *   disk-full          — Detailed disk + NFS mount + inode check on NetCup
 */

import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { execSync, spawn } from "child_process";
import * as fs from "node:fs";

// ── Minimal YAML parser (replaces ./yaml-simple) ─────────────────────────────
function parseSimpleYaml(text: string): Record<string, Record<string, string>> {
  const result: Record<string, Record<string, string>> = {};
  let current: string | null = null;
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const topMatch = trimmed.match(/^(\S+):\s*$/);
    if (topMatch) { current = topMatch[1]; result[current] = {}; continue; }
    if (current) {
      const kvMatch = trimmed.match(/^(\S+):\s*(.*)/);
      if (kvMatch) result[current][kvMatch[1]] = kvMatch[2].trim().replace(/^['"]|['"]$/g, "");
    }
  }
  return result;
}

// ── Config ──────────────────────────────────────────────────────────────────

const ENV_FILE = path.join(os.homedir(), "pi-infra", "config", "coms-net.env");

function loadEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  if (fs.existsSync(ENV_FILE)) {
    for (const line of fs.readFileSync(ENV_FILE, "utf-8").split("\n")) {
      const m = line.match(/^([A-Z_]+)=(.*)$/);
      if (m) env[m[1]] = m[2];
    }
  }
  return env;
}

const env = loadEnv();
const SERVER_URL = (env.PI_COMS_NET_PUBLIC_URL || "http://localhost:8090").replace(/\/$/, "");
const AUTH_TOKEN = env.PI_COMS_NET_AUTH_TOKEN || "";
// Stable session ID — survives reconnects without creating orphan sessions
const SESSION_ID = `hermes-ops-stable`;
const PROJECT = "default";
const SSE_RECONNECT_BASE_MS = 2000;
const SSE_RECONNECT_MAX_MS = 30000;
const HEARTBEAT_INTERVAL_MS = 10000;
const HEARTBEAT_FAIL_THRESHOLD = 3; // after N consecutive heartbeat failures, force reconnect

const NETCUP_HOST = "193.26.156.15";
const SSH_OPTS = "-i ~/.ssh/id_ed25519 -o ConnectTimeout=10 -o StrictHostKeyChecking=no";

const DEPLOY_MAP_FILE = path.join(os.homedir(), "pi-infra", "config", "deploy-map.yaml");
const EVENTS_LOG_FILE = path.join(os.homedir(), "pi-infra", "logs", "events.jsonl");
const MEMORY_FILE = path.join(os.homedir(), "pi-infra", "data", "bridge-memory.json");

interface DeployTarget {
  path: string;
  command: string;
  verify: string;
  branch: string;
}

let deployMap: Record<string, DeployTarget> = {};

function loadDeployMap(): void {
  try {
    if (fs.existsSync(DEPLOY_MAP_FILE)) {
      const raw = fs.readFileSync(DEPLOY_MAP_FILE, "utf-8");
      deployMap = parseSimpleYaml(raw) as Record<string, Record<string, string>> as unknown as Record<string, DeployTarget>;
    }
  } catch (e) {
    console.error(`Failed to load deploy map: ${e}`);
  }
}

function logEvent(entry: Record<string, any>): void {
  try {
    const dir = path.dirname(EVENTS_LOG_FILE);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(EVENTS_LOG_FILE, JSON.stringify({ ts: new Date().toISOString(), ...entry }) + "\n");
  } catch { /* best effort */ }
}

// ── Persistent memory ───────────────────────────────────────────────────────

interface MemoryStore {
  [key: string]: any;
}

let memory: MemoryStore = {};

function readMemory(): MemoryStore {
  try {
    if (fs.existsSync(MEMORY_FILE)) {
      memory = JSON.parse(fs.readFileSync(MEMORY_FILE, "utf-8"));
    }
  } catch {
    memory = {};
  }
  return memory;
}

function writeMemory(updates: Record<string, any>): void {
  try {
    const dir = path.dirname(MEMORY_FILE);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    Object.assign(memory, updates);
    fs.writeFileSync(MEMORY_FILE, JSON.stringify(memory, null, 2));
  } catch (e) {
    console.error(`Memory write failed: ${e}`);
  }
}

function memoryGet(key: string): any {
  return memory[key];
}

// ── HTTP ────────────────────────────────────────────────────────────────────

async function api(method: string, urlPath: string, body?: object): Promise<any> {
  const headers: Record<string, string> = {
    "Authorization": `Bearer ${AUTH_TOKEN}`,
  };
  if (body) headers["Content-Type"] = "application/json";
  const resp = await fetch(`${SERVER_URL}${urlPath}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  return resp.json();
}

function ssh(cmd: string, timeout = 30): string {
  try {
    return execSync(`ssh ${SSH_OPTS} root@${NETCUP_HOST} "${cmd.replace(/"/g, '\\"')}"`, {
      timeout: timeout * 1000,
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch (e: any) {
    // execSync throws on non-zero exit code but stdout may have useful output
    const stdout = e.stdout?.toString() || "";
    const stderr = e.stderr?.toString() || "";
    if (stdout.trim()) return stdout + (stderr.trim() ? `\nSTDERR: ${stderr.trim()}` : "");
    return `ERROR: ${e.message.split("\n")[0]}${stderr.trim() ? `\n${stderr.trim()}` : ""}`;
  }
}

// ── Commands ────────────────────────────────────────────────────────────────

const COMMANDS: Record<string, (args: string) => string> = {
  health: (_args) => {
    return ssh("docker ps --format '{{.Names}}\\t{{.Status}}' 2>/dev/null | head -30");
  },
  deploy: (args) => {
    const project = args.trim();
    if (!project) return "Usage: deploy <project-name>";
    return ssh(`cd /root/projects/${project} && git pull && docker-compose up -d --build 2>&1 | tail -15`, 120);
  },
  logs: (args) => {
    const parts = args.trim().split(" ");
    const project = parts[0] || "";
    const lines = parts[1] || "50";
    if (!project) return "Usage: logs <project-name> [lines]";
    return ssh(`cd /root/projects/${project} && docker-compose logs --tail=${lines} 2>&1 | tail -60`);
  },
  status: () => {
    return ssh("docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}' 2>/dev/null | head -30");
  },
  disk: () => {
    return ssh("df -h / && echo '---' && docker system df 2>/dev/null");
  },
  restart: (args) => {
    const project = args.trim();
    if (!project) return "Usage: restart <project-name>";
    return ssh(`cd /root/projects/${project} && docker-compose restart 2>&1 | tail -10`, 60);
  },
  rollback: (args) => {
    const project = args.trim();
    if (!project) return "Usage: rollback <project-name>";
    return ssh(`cd /root/projects/${project} && git reset --hard HEAD~1 && docker-compose up -d --build 2>&1 | tail -10`, 120);
  },

  // Backup status — checks last backup, does NOT run the dump
  backup: () => {
    return ssh("bash /root/scripts/backup-status.sh 2>&1");
  },

  // Pi command — runs pi on this VPS with a prompt in a project directory
  // Usage: pi <project> <prompt...>
  // Example: pi resiliently-ai /prime
  pi: (args) => {
    // Synchronous stub — actual spawn is async, handled in dispatch below
    return `__PI_ASYNC__:${args}`;
  },

  // Detailed disk + NFS + inode check
  "disk-full": () => {
    return ssh("bash /root/scripts/disk-full.sh 2>&1");
  },

  // Memory commands
  "memory": () => {
    return JSON.stringify(memory, null, 2);
  },
  "last-deploy": (args) => {
    const project = args.trim();
    if (!project) return "Usage: last-deploy <project>";
    const info = memoryGet(`last_deploy:${project}`);
    if (!info) return `No deploy recorded for ${project}`;
    return `Last deploy of ${project}:\n  Time: ${info.timestamp}\n  Commit: ${info.commit || "N/A"}\n  Status: ${info.status}\n  Triggered by: ${info.triggered_by || "manual"}`;
  },
  "last-event": () => {
    const count = memoryGet("events_processed") || 0;
    return `Total events processed: ${count}`;
  },
  "summary": () => {
    return generateSummary();
  },

  // Event handlers — dispatched by handleEventCommand below
  "event": () => "Use event:<type> syntax (e.g. event:push project=X branch=main)",
};

function generateSummary(): string {
  const lines: string[] = ["hermes-ops summary:"];

  // Deploys
  const deployKeys = Object.keys(memory).filter(k => k.startsWith("last_deploy:"));
  if (deployKeys.length > 0) {
    lines.push("");
    lines.push("Recent Deploys:");
    for (const key of deployKeys) {
      const d = memory[key];
      const proj = key.replace("last_deploy:", "");
      const age = d.timestamp ? timeSince(d.timestamp) : "unknown";
      lines.push(`  ${proj}: ${d.status} (${age} ago, by ${d.triggered_by || "manual"})`);
    }
  }

  // Counters
  const eventsProcessed = memoryGet("events_processed") || 0;
  const deploysTotal = memoryGet("deploys_total") || 0;
  const deploysFailed = memoryGet("deploys_failed") || 0;
  lines.push("");
  lines.push(`Events processed: ${eventsProcessed}`);
  lines.push(`Deploys: ${deploysTotal} total, ${deploysFailed} failed`);

  // Last status check
  const lastStatus = memoryGet("last_status_check");
  if (lastStatus) {
    lines.push("");
    lines.push(`Last status: ${lastStatus.containers_running || "?"} running, ${lastStatus.containers_stopped || "?"} stopped, disk ${lastStatus.disk_pct || "?"}%`);
  }

  // Last backup
  const lastBackup = memoryGet("last_backup");
  if (lastBackup) {
    lines.push(`Last backup: ${lastBackup.size || "?"} (${timeSince(lastBackup.timestamp)} ago)`);
  }

  return lines.join("\n");
}

function timeSince(isoStr: string): string {
  try {
    const diff = Date.now() - new Date(isoStr).getTime();
    const mins = Math.floor(diff / 60000);
    if (mins < 60) return `${mins}m`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs}h`;
    return `${Math.floor(hrs / 24)}d`;
  } catch {
    return "?";
  }
}

// ── Event command parser ──────────────────────────────────────────────────

function handleEventCommand(prompt: string): string {
  // Format: event:<type> project=<proj> [key=value ...]
  const parts = prompt.trim().split(/\s+/);
  const typePart = parts[0]; // e.g. "event:push"
  if (!typePart || !typePart.startsWith("event:")) {
    return "Invalid event format. Use event:<type> project=X ...";
  }

  const eventType = typePart.slice(6); // "push", "issue.opened", etc.
  const kv: Record<string, string> = {};
  for (const part of parts.slice(1)) {
    const eq = part.indexOf("=");
    if (eq > 0) kv[part.slice(0, eq)] = part.slice(eq + 1);
  }

  const project = kv.project || "unknown";

  // Log all events
  logEvent({ event_type: eventType, project, raw: prompt, ...kv });

  switch (eventType) {
    case "push": {
      return handleEventPush(kv);
    }
    case "issue.opened":
    case "issue.labeled":
    case "issue.closed": {
      return `📋 Event logged: ${eventType} on ${project}` + (kv.title ? ` — "${kv.title}"` : "");
    }
    case "pr.merged":
    case "pr.closed": {
      return `🔀 Event logged: ${eventType} on ${project}` + (kv.title ? ` — "${kv.title}"` : "");
    }
    case "payment": {
      const amount = kv.amount ? `$${(parseInt(kv.amount) / 100).toFixed(2)}` : "unknown";
      return `💰 Payment logged: ${amount} on ${project}`;
    }
    case "signup": {
      return `👤 Signup logged: new user on ${project}`;
    }
    default: {
      return `Unknown event type: ${eventType}`;
    }
  }
}

function handleEventPush(kv: Record<string, string>): string {
  const project = kv.project || "unknown";
  const branch = kv.branch || "unknown";
  const pusher = kv.by || "unknown";
  const commits = kv.commits || "0";

  // Feedback loop prevention: skip agent pushes
  if (pusher.startsWith("Hermes") || pusher === "bobbiejaxn-bot" || pusher === "bobbiejaxn[bot]") {
    logEvent({ event_type: "push_skipped", reason: "agent_push", project, branch, by: pusher });
    return `⏭️ Skipped deploy: agent push by ${pusher} on ${project}/${branch}`;
  }

  // Check deploy map
  const target = deployMap[project];
  if (!target) {
    return `📦 Push logged: ${commits} commit(s) by ${pusher} on ${project}/${branch}. No deploy config — skipping.`;
  }

  // Check branch
  const deployBranch = target.branch || "main";
  if (branch !== deployBranch) {
    return `📦 Push logged: ${commits} commit(s) by ${pusher} on ${project}/${branch}. Branch mismatch (need ${deployBranch}) — skipping.`;
  }

  // Deploy!
  logEvent({ event_type: "deploy_start", project, branch, by: pusher, commits, triggered_by: "event:push" });
  const result = ssh(
    `cd ${target.path} && ${target.command} 2>&1 | tail -20`,
    120
  );

  // Verify
  let verifyResult = "";
  if (target.verify) {
    try {
      verifyResult = ssh(target.verify, 15);
      const status = verifyResult.trim();
      if (status.match(/^[23]\d\d$/)) {
        logEvent({ event_type: "deploy_success", project, branch, by: pusher, http_status: status });
        return `🚀 Deployed ${project} (${commits} commit(s) by ${pusher})\nHTTP ${status} ✓\n\n${result.slice(-500)}`;
      } else {
        logEvent({ event_type: "deploy_verify_warn", project, branch, by: pusher, http_status: status });
        return `⚠️ Deployed ${project} but verify returned: ${status}\n\n${result.slice(-500)}`;
      }
    } catch {
      return `🚀 Deployed ${project} (verify failed)\n\n${result.slice(-500)}`;
    }
  }

  logEvent({ event_type: "deploy_success", project, branch, by: pusher });
  writeMemory({
    [`last_deploy:${project}`]: {
      timestamp: new Date().toISOString(),
      commit: "latest",
      status: "success",
      triggered_by: "event:push",
      by: pusher,
    },
    deploys_total: (memoryGet("deploys_total") || 0) + 1,
  });
  return `🚀 Deployed ${project} (${commits} commit(s) by ${pusher})\n\n${result.slice(-500)}`;
}

// ── Memory update after commands ───────────────────────────────────────────

function updateMemoryForCommand(cmd: string, args: string, response: string): void {
  const now = new Date().toISOString();
  switch (cmd) {
    case "health":
    case "status": {
      // Parse container count from response
      const lines = response.split("\n").filter(l => l.trim() && !l.includes("NAMES"));
      writeMemory({
        last_status_check: {
          timestamp: now,
          containers_running: lines.length,
          containers_stopped: (response.match(/Exited/g) || []).length,
          disk_pct: null,
        },
      });
      break;
    }
    case "disk": {
      const pctMatch = response.match(/(\/dev\/\S+)\s+\S+\s+\S+\s+\S+\s+(\d+)%/);
      writeMemory({
        last_disk_check: {
          timestamp: now,
          disk_pct: pctMatch ? parseInt(pctMatch[2]) : null,
          filesystem: pctMatch ? pctMatch[1] : null,
        },
      });
      break;
    }
    case "deploy": {
      const project = args.trim();
      const success = !response.includes("ERROR");
      writeMemory({
        [`last_deploy:${project}`]: {
          timestamp: now,
          commit: "latest",
          status: success ? "success" : "failed",
          triggered_by: "manual",
        },
        deploys_total: (memoryGet("deploys_total") || 0) + 1,
        ...(success ? {} : { deploys_failed: (memoryGet("deploys_failed") || 0) + 1 }),
      });
      break;
    }
    case "backup": {
      const sizeMatch = response.match(/(\d+[KMG]?B)/i);
      writeMemory({
        last_backup: {
          timestamp: now,
          size: sizeMatch ? sizeMatch[1] : "unknown",
        },
      });
      break;
    }
  }
}

// ── Register + SSE ──────────────────────────────────────────────────────────

let heartbeatFailures = 0;
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
let running = true;

async function main(): Promise<void> {
  console.log("hermes-coms-bridge starting...");
  console.log(`  Server: ${SERVER_URL}`);
  console.log(`  Session: ${SESSION_ID}`);

  // Load deploy map
  loadDeployMap();
  console.log(`  Deploy map: ${Object.keys(deployMap).length} projects`);

  // Load persistent memory
  readMemory();
  console.log(`  Memory: ${Object.keys(memory).length} keys`);

  // Main loop: register → SSE → reconnect on failure
  while (running) {
    try {
      await connectLoop();
    } catch (e: any) {
      console.error(`Connection error: ${e.message}`);
    }

    if (!running) break;

    // Exponential backoff before reconnect
    let delay = SSE_RECONNECT_BASE_MS;
    for (let attempt = 1; running; attempt++) {
      console.log(`Reconnecting in ${delay / 1000}s (attempt ${attempt})...`);
      await sleep(delay);
      if (!running) break;

      // Try to re-register
      try {
        await register();
        break; // success, go back to connectLoop
      } catch {
        delay = Math.min(delay * 2, SSE_RECONNECT_MAX_MS);
      }
    }
  }
}

async function connectLoop(): Promise<void> {
  // Register
  const reg = await register();

  const sseUrl = `${SERVER_URL}${reg.sse_url}`;
  console.log(`  SSE: ${sseUrl}`);

  // Start heartbeat
  heartbeatFailures = 0;
  if (heartbeatTimer) clearInterval(heartbeatTimer);
  heartbeatTimer = setInterval(async () => {
    try {
      const res = await api("POST", `/v1/agents/${SESSION_ID}/heartbeat?project=${PROJECT}`, {
        context_used_pct: 0, queue_depth: 0, status: "online",
      });
      if (!res.ok) {
        heartbeatFailures++;
        console.error(`  Heartbeat failed (${heartbeatFailures}/${HEARTBEAT_FAIL_THRESHOLD}): ${res.error || "unknown"}`);

        // If agent_not_found, re-register immediately (hub lost our session)
        if (res.error === "agent_not_found" || (typeof res.error === "string" && res.error.includes("agent_not_found"))) {
          console.log("  Agent not found - re-registering immediately...");
          try {
            await register();
            heartbeatFailures = 0;
            console.log("  Re-registered successfully, heartbeat restored");
          } catch (regErr: unknown) {
            console.error(`  Re-registration failed: ${regErr instanceof Error ? regErr.message : String(regErr)}`);
            if (heartbeatFailures >= HEARTBEAT_FAIL_THRESHOLD) {
              console.error("  Too many failures after re-register attempt - forcing SSE reconnect");
              throw new Error("heartbeat_threshold_exceeded");
            }
          }
        } else if (heartbeatFailures >= HEARTBEAT_FAIL_THRESHOLD) {
          console.error("  Too many heartbeat failures - forcing reconnect");
          throw new Error("heartbeat_threshold_exceeded");
        }
      } else {
        if (heartbeatFailures > 0) {
          console.log(`  Heartbeat recovered after ${heartbeatFailures} failures`);
        }
        heartbeatFailures = 0;
      }
    } catch (e: any) {
      heartbeatFailures++;
      console.error(`  Heartbeat error (${heartbeatFailures}/${HEARTBEAT_FAIL_THRESHOLD}): ${e.message}`);
      if (heartbeatFailures >= HEARTBEAT_FAIL_THRESHOLD) {
        console.error("  Too many heartbeat failures — forcing reconnect");
      }
    }
  }, HEARTBEAT_INTERVAL_MS);

  // Connect to SSE stream
  const resp = await fetch(sseUrl, {
    headers: { "Authorization": `Bearer ${AUTH_TOKEN}` },
  });

  if (!resp.ok || !resp.body) {
    console.error(`SSE connection failed: ${resp.status}`);
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    throw new Error(`SSE failed: ${resp.status}`);
  }

  console.log("  SSE connected. Listening for messages...");

  // Parse SSE stream
  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let currentEvent = "";
  let currentData = "";

  try {
    while (running) {
      const { done, value } = await reader.read();
      if (done) {
        console.log("  SSE stream ended (server closed connection)");
        break;
      }

      // Check if heartbeat threshold was hit while reading
      if (heartbeatFailures >= HEARTBEAT_FAIL_THRESHOLD) {
        console.log("  Aborting SSE stream due to heartbeat failures");
        reader.cancel();
        break;
      }

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";

      for (const line of lines) {
        if (line.startsWith("event: ")) {
          currentEvent = line.slice(7).trim();
        } else if (line.startsWith("data: ")) {
          currentData = line.slice(6);
        } else if (line === "" && currentData) {
          try {
            const data = JSON.parse(currentData);
            handleEvent(currentEvent, data);
          } catch { /* ignore parse errors */ }
          currentEvent = "";
          currentData = "";
        }
      }
    }
  } finally {
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    // Do NOT unregister here - creates a window where heartbeat-probe cannot find us.
    // The main loop will unregister + re-register on next iteration if needed.
  }
}

async function register(): Promise<any> {
  // First try to clean up any stale session with our ID
  try { await api("DELETE", `/v1/agents/${SESSION_ID}?project=${PROJECT}`); } catch { /* */ }

  const reg = await api("POST", "/v1/agents/register", {
    project: PROJECT,
    session_id: SESSION_ID,
    name: "hermes-ops",
    purpose: "Operations hub — deploys to NetCup, monitors production",
    model: "zai/glm-5.1",
    provider: "zai",
    color: "#FF7EDB",
    cwd: "/root/pi_launchpad",
    explicit: false,
  });

  if (!reg.ok) {
    throw new Error(`Registration failed: ${reg.error}`);
  }
  console.log(`  Registered: OK`);
  return reg;
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function handleEvent(event: string, data: any): void {
  if (event === "prompt") {
    // This is already routed to our SSE stream — it's for us
    const prompt = data.prompt || "";
    const sender = data.sender?.name || "unknown";
    const msgId = data.msg_id;
    console.log(`← [${sender}] ${prompt.slice(0, 100)}`);

    const parts = prompt.trim().split(/\s+/);
    const cmd = parts[0]?.toLowerCase() || "";
    const args = parts.slice(1).join(" ");

    let response: string;
    if (cmd.startsWith("event:")) {
      // Route all event:* messages to the event handler
      response = handleEventCommand(prompt.trim());
      // Memory update for events
      const eventsProcessed = (memoryGet("events_processed") || 0) + 1;
      writeMemory({ events_processed: eventsProcessed });
    } else if (COMMANDS[cmd]) {
      response = COMMANDS[cmd](args);
      // Update memory based on command
      updateMemoryForCommand(cmd, args, response);
    } else if (["memory", "last-deploy", "last-event", "summary"].includes(cmd)) {
      response = COMMANDS[cmd](args);
    } else {
      response = `hermes-ops received: "${prompt}"\n\nDirect commands: health, deploy, logs, status, disk, disk-full, backup, restart, rollback, memory, last-deploy, last-event, summary\nPi commands: pi <project> <prompt> (e.g. pi resiliently-ai /prime)\nEvent commands: event:push, event:issue.opened, event:pr.merged, event:payment, event:signup`;
    }

    // Handle pi command async spawn
    if (cmd === "pi" && response.startsWith("__PI_ASYNC__:")) {
      const piArgs = response.slice("__PI_ASYNC__:".length);
      const parts = piArgs.trim().split(/\s+/);
      const project = parts[0] || "";
      const projectDir = `/root/projects/active/${project}`;
      const piPrompt = parts.slice(1).join(" ");
      const timeoutMs = 300000; // 5 min

      // Send immediate ack
      api("POST", `/v1/messages/${msgId}/response?project=${PROJECT}`, {
        responder_session: SESSION_ID,
        response: `[pi] Started in ${project}: ${piPrompt}\nRunning...`,
        error: null,
      });

      // Spawn pi async
      console.log(`  [pi] Spawning async in ${projectDir}: ${piPrompt}`);
      const child = spawn("pi", [piPrompt], {
        cwd: projectDir,
        env: { ...process.env },
        stdio: ["pipe", "pipe", "pipe"],
      });

      let stdout = "";
      let stderr = "";
      child.stdout.on("data", (d: Buffer) => { stdout += d.toString(); });
      child.stderr.on("data", (d: Buffer) => { stderr += d.toString(); });

      const timer = setTimeout(() => {
        console.log(`  [pi] Timeout, killing`);
        child.kill("SIGTERM");
      }, timeoutMs);

      child.on("error", (err: Error) => {
        console.error(`  [pi] spawn error: ${err.message}`);
      });
      child.on("exit", (code: number | null, signal: string | null) => {
        console.log(`  [pi] exit event: code=${code} signal=${signal}`);
      });
      child.on("close", (code: number | null) => {
        clearTimeout(timer);
        const exitCode = code ?? -1;
        const output = stdout.trim().slice(-4000);
        const prefix = exitCode !== 0 ? `[pi] Exit code ${exitCode}\n` : "[pi] Completed\n";
        const result = prefix + output + (stderr.trim() ? "\nSTDERR: " + stderr.trim().slice(-500) : "");
        console.log(`  [pi] Done (${exitCode}), sending response`);

        // Submit final response as a NEW message (can't update the ack'd one)
        api("POST", `/v1/messages?project=${PROJECT}`, {
          sender_session: SESSION_ID,
          target: data.sender?.session_id || "local-dev-mac",
          prompt: result,
        }).catch((e: any) => console.error(`Pi result send failed: ${e.message}`));
      });

      return; // Don't submit the normal response below
    }

    // Submit response
    api("POST", `/v1/messages/${msgId}/response?project=${PROJECT}`, {
      responder_session: SESSION_ID,
      response,
      error: null,
    }).then(() => console.log(`→ response sent (${response.length} chars)`))
      .catch((e) => console.error(`Response failed: ${e.message}`));
  }
}

// Graceful shutdown
async function shutdown() {
  console.log("\nShutting down...");
  running = false;
  if (heartbeatTimer) clearInterval(heartbeatTimer);
  try {
    await api("DELETE", `/v1/agents/${SESSION_ID}?project=${PROJECT}`);
    console.log("  Unregistered");
  } catch { /* best effort */ }
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

main().catch((e) => {
  console.error(`Fatal: ${e.message}`);
  process.exit(1);
});
