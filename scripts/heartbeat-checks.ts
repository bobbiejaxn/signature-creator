/**
 * heartbeat-checks.ts — Node.js internal checks for heartbeat.sh
 * Run via: npx tsx scripts/heartbeat-checks.ts
 * Exit: 0 = all pass, 1 = any fail
 * Output: JSON lines per check
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync, rmSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

let total = 0;
let passed = 0;

function report(name: string, pass: boolean, detail: string) {
	total++;
	if (pass) passed++;
	console.log(JSON.stringify({ name, pass, detail }));
}

async function main() {
	// ── 1. Merge Resolver ──────────────────────────────────────────────────
	try {
		const mr = await import("../.pi/extensions/subagent/merge-resolver.js");
		const input = "a\n<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> b\nc";
		const resolved = mr.resolveConflictsKeepIncoming(input);
		report("merge-resolver: keep-incoming", resolved === "a\nnew\nc", "conflict resolved correctly");

		const contentful = mr.hasContentfulCanonical("<<<<<<< HEAD\ncode\n=======\nnew\n>>>>>>> b");
		report("merge-resolver: contentful-detect", contentful === true, `hasContentfulCanonical=${contentful}`);

		const isProse = mr.looksLikeProse("I will resolve this conflict");
		report("merge-resolver: prose-detect", isProse === true, `looksLikeProse=${isProse}`);

		const isCode = mr.looksLikeProse("const x = 1;");
		report("merge-resolver: code-pass", isCode === false, `looksLikeProse=${isCode}`);
	} catch (e: unknown) {
		const msg = e instanceof Error ? e.message : String(e);
		report("merge-resolver", false, `import failed: ${msg}`);
	}

	// ── 2. Health Evaluator ────────────────────────────────────────────────
	try {
		const hl = await import("../.pi/extensions/session-intel/health.js");
		const recent = new Date(Date.now() - 1000).toISOString();
		const dead = hl.evaluateHealth(
			{ agentName: "w", pid: 99999999, state: "working", lastActivity: recent },
			{ staleMs: 300000, zombieMs: 1800000 },
		);
		report("health-evaluator: pid-dead→zombie", dead.state === "zombie" && dead.action === "terminate", `state=${dead.state}`);

		const alive = hl.evaluateHealth(
			{ agentName: "w", pid: null, state: "working", lastActivity: recent },
			{ staleMs: 300000, zombieMs: 1800000 },
		);
		report("health-evaluator: pid-null→working", alive.state === "working" && alive.action === "none", `state=${alive.state}`);

		const forward = hl.transitionState("zombie", { state: "working", action: "none" } as any);
		report("health-evaluator: forward-only", forward === "zombie", `transition=${forward}`);

		const hold = hl.transitionState("working", { state: "zombie", action: "investigate" } as any);
		report("health-evaluator: investigate-hold", hold === "working", `transition=${hold}`);
	} catch (e: unknown) {
		const msg = e instanceof Error ? e.message : String(e);
		report("health-evaluator", false, `import failed: ${msg}`);
	}

	// ── 3. Mid-session Learning I/O ────────────────────────────────────────
	{
		const dir = join(homedir(), ".pi", "session-learnings");
		const testId = `heartbeat-${Date.now()}`;
		const file = join(dir, `${testId}.jsonl`);
		try {
			mkdirSync(dir, { recursive: true });
			writeFileSync(file, JSON.stringify({ type: "test", count: 1 }) + "\n");
			const lines = readFileSync(file, "utf-8").split("\n").filter((l) => l.trim());
			const parsed = JSON.parse(lines[0]);
			unlinkSync(file);
			report("mid-session-learning: I/O cycle", parsed.type === "test" && parsed.count === 1, "write→read→parse→delete");
		} catch (e: unknown) {
			const msg = e instanceof Error ? e.message : String(e);
			report("mid-session-learning", false, msg);
			try { unlinkSync(file); } catch { /* cleanup */ }
		}
	}

	// ── 4. Steer file mechanism ────────────────────────────────────────────
	{
		const steerDir = join(homedir(), ".pi", "steer", `heartbeat-${Date.now()}`);
		const steerFile = join(steerDir, "test-agent.md");
		try {
			mkdirSync(steerDir, { recursive: true });
			writeFileSync(steerFile, "test steer message");
			const content = readFileSync(steerFile, "utf-8");
			report("steer-mechanism: file I/O", content.includes("test steer message"), "write→read→verify");
		} catch (e: unknown) {
			const msg = e instanceof Error ? e.message : String(e);
			report("steer-mechanism", false, msg);
		} finally {
			try { rmSync(steerDir, { recursive: true, force: true }); } catch { /* cleanup */ }
		}
	}

	// ── Summary ────────────────────────────────────────────────────────────
	console.log(JSON.stringify({ summary: true, total, passed, failed: total - passed }));
	process.exit(total === passed ? 0 : 1);
}

main().catch((e) => {
	console.error(e);
	process.exit(2);
});
